//
//  LumixDiscovery.swift
//  Lumix Bridge
//
//  Finds the camera without a hardcoded IP.
//
//  Deliberately does NOT use SSDP or mDNS: SSDP on iOS requires the
//  com.apple.developer.networking.multicast entitlement, which Apple grants only
//  on written request. A plain TCP/HTTP sweep of the local subnet needs only the
//  ordinary local-network permission and finishes in about a second, so the
//  entitlement isn't worth it.
//
//  Cameras are keyed by UDN, never by address, so DHCP reassignment is invisible.
//

import Foundation
import Darwin

// MARK: - Interface enumeration

enum LocalNetwork {
    struct Interface: Sendable {
        let name: String
        let address: String
        let netmask: String
    }

    static func ipv4Interfaces() -> [Interface] {
        var results: [Interface] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP == IFF_UP,
                  flags & IFF_LOOPBACK == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }

            var maskString = "255.255.255.0"
            if let nm = ptr.pointee.ifa_netmask {
                var mask = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(nm, socklen_t(nm.pointee.sa_len),
                               &mask, socklen_t(mask.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    maskString = String(cString: mask)
                }
            }
            results.append(Interface(name: String(cString: ptr.pointee.ifa_name),
                                     address: String(cString: host),
                                     netmask: maskString))
        }
        // Wi-Fi first — that's where the camera lives.
        return results.sorted { a, b in
            (a.name == "en0" ? 0 : 1) < (b.name == "en0" ? 0 : 1)
        }
    }

    /// Host addresses on the same subnet, excluding network/broadcast and self.
    /// Capped at a /24 worth of hosts so a wide netmask can't explode the sweep.
    static func hosts(for iface: Interface, maxHosts: Int = 254) -> [String] {
        func toUInt32(_ s: String) -> UInt32? {
            let parts = s.split(separator: ".").compactMap { UInt32($0) }
            guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
            return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
        }
        func toString(_ v: UInt32) -> String {
            "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
        }
        guard let ip = toUInt32(iface.address), var mask = toUInt32(iface.netmask) else {
            return []
        }
        // Never scan wider than a /24.
        let slash24: UInt32 = 0xFFFFFF00
        if mask < slash24 { mask = slash24 }

        let network = ip & mask
        let broadcast = network | ~mask
        guard broadcast > network else { return [] }

        var out: [String] = []
        out.reserveCapacity(maxHosts)
        var a = network &+ 1
        while a < broadcast && out.count < maxHosts {
            if a != ip { out.append(toString(a)) }
            a &+= 1
        }
        return out
    }
}

// MARK: - Discovery

public struct DiscoveredCamera: Sendable, Equatable {
    public let host: String
    public let info: CameraInfo
}

public actor LumixDiscovery {

    private let transport: LumixTransport
    /// Kept modest: iOS gets file-descriptor pressure long before macOS does.
    private let maxConcurrent = 64
    private let probeTimeout: TimeInterval = 1.2

    private var cachedHost: String?

    public init(transport: LumixTransport) {
        self.transport = transport
    }

    /// Remembered address for the last camera we talked to.
    public func seedCache(host: String?) { cachedHost = host }

    /// Locate a camera. If `udn` is given only that specific body matches.
    public func find(udn: String? = nil) async -> DiscoveredCamera? {
        // 1. Cached address — by far the common case, ~40ms.
        if let host = cachedHost {
            if let info = await transport.describe(host: host, timeout: 1.5),
               udn == nil || info.udn == udn {
                logInfo(.discovery, "cache hit \(host) — \(info.modelNumber)")
                return DiscoveredCamera(host: host, info: info)
            }
            logDebug(.discovery, "cached host \(host) did not answer; sweeping")
        }

        // 2. Sweep every local subnet.
        for iface in LocalNetwork.ipv4Interfaces() {
            let hosts = LocalNetwork.hosts(for: iface)
            guard !hosts.isEmpty else { continue }
            logInfo(.discovery,
                    "sweeping \(hosts.count) hosts on \(iface.name) (\(iface.address))")

            let started = Date()
            if let found = await sweep(hosts: hosts, udn: udn) {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                logInfo(.discovery,
                        "found \(found.info.modelNumber) at \(found.host) in \(ms)ms")
                cachedHost = found.host
                return found
            }
            logDebug(.discovery, "no camera on \(iface.name)")
        }
        return nil
    }

    /// Bounded-concurrency probe; returns as soon as a match appears.
    /// Written as flat loops rather than a nested helper because a nested
    /// function can't capture the `inout` task group.
    private func sweep(hosts: [String], udn: String?) async -> DiscoveredCamera? {
        let transport = self.transport
        let timeout = self.probeTimeout

        return await withTaskGroup(of: DiscoveredCamera?.self) { group in
            var index = 0
            var running = 0

            // Prime the window.
            while index < min(maxConcurrent, hosts.count) {
                let host = hosts[index]
                index += 1
                running += 1
                group.addTask {
                    guard let info = await transport.describe(host: host, timeout: timeout,
                                                              quiet: true) else { return nil }
                    return DiscoveredCamera(host: host, info: info)
                }
            }

            var found: DiscoveredCamera?
            while running > 0 {
                guard let result = await group.next() else { break }
                running -= 1

                if let candidate = result, udn == nil || candidate.info.udn == udn {
                    found = candidate
                    break
                }
                // Backfill the window with the next host.
                if index < hosts.count {
                    let host = hosts[index]
                    index += 1
                    running += 1
                    group.addTask {
                        guard let info = await transport.describe(host: host, timeout: timeout,
                                                                  quiet: true) else { return nil }
                        return DiscoveredCamera(host: host, info: info)
                    }
                }
            }
            group.cancelAll()
            return found
        }
    }
}
