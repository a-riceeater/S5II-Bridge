//
//  LumixLiveView.swift
//  Lumix Bridge
//
//  The live-view stream is NOT optional.
//
//  Measured on DC-S5M2 fw 3.61: with keepalive alone the camera falls out of
//  cammode=rec after ~2 seconds, and video_recstart then fails with
//  err_critical. With `startstream` running it holds cammode=rec indefinitely
//  (45s+ observed). So the stream is what keeps the body in remote-shooting
//  mode — it is a prerequisite for a reliable shutter, not a luxury.
//
//  Because we are paying for it regardless, decoding it is nearly free, and the
//  frames can optionally be displayed. When the preview is hidden we still run
//  the socket (the camera needs a live receiver) but skip JPEG decoding, and we
//  ask for the smallest frame size.
//
//  Wire format: one UDP datagram per frame — a proprietary Panasonic header
//  followed by a complete JPEG. Locating the SOI marker (FF D8) is enough.
//

import Foundation
import Network
import Observation

#if canImport(UIKit)
import UIKit
#endif

public enum LiveViewSize: String, Sendable, CaseIterable {
    case qvga, vga, low, standard, fine
}

@MainActor
@Observable
public final class LumixLiveView {

    public private(set) var isRunning = false
    public private(set) var framesReceived = 0
    public private(set) var bytesReceived = 0
    public private(set) var lastFrameAt: Date?

    #if canImport(UIKit)
    /// Latest decoded frame. Only populated while `decodeFrames` is true.
    public private(set) var image: UIImage?
    #endif

    /// When false the socket still drains (the camera needs a receiver) but we
    /// skip the JPEG decode entirely.
    public var decodeFrames = false {
        didSet {
            #if canImport(UIKit)
            if !decodeFrames { image = nil }
            #endif
        }
    }

    public let port: UInt16
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "lumix.liveview", qos: .userInitiated)

    public init(port: UInt16 = 49199) {
        self.port = port
    }

    /// Binds the UDP port. Call BEFORE asking the camera to start streaming, so
    /// the first datagrams aren't met with ICMP port-unreachable.
    public func start() throws {
        guard !isRunning else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LumixError.transport("bad live-view port \(port)")
        }
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            Task { @MainActor in self.connections.append(connection) }
            self.receive(on: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        isRunning = true
        logInfo(.session, "live-view socket listening on udp/\(port)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isRunning = false
        #if canImport(UIKit)
        image = nil
        #endif
        logInfo(.session, "live-view socket closed")
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in self.handle(data) }
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ datagram: Data) {
        framesReceived += 1
        bytesReceived += datagram.count
        lastFrameAt = Date()

        #if canImport(UIKit)
        guard decodeFrames else { return }
        guard let jpeg = Self.extractJPEG(datagram),
              let img = UIImage(data: jpeg) else { return }
        image = img
        #endif
    }

    /// Strips the Panasonic header by seeking the JPEG start-of-image marker.
    /// The header length is not fixed across models, so scanning beats assuming.
    static func extractJPEG(_ data: Data) -> Data? {
        guard data.count > 4 else { return nil }
        // Bound the search: the header is small, a few hundred bytes at most.
        let limit = min(data.count - 1, 512)
        for i in 0..<limit {
            if data[data.startIndex + i] == 0xFF,
               data[data.startIndex + i + 1] == 0xD8 {
                return data.subdata(in: (data.startIndex + i)..<data.endIndex)
            }
        }
        return nil
    }

    public var throughputDescription: String {
        guard framesReceived > 0 else { return "no frames" }
        let kb = Double(bytesReceived) / 1024.0
        return String(format: "%d frames · %.0f KB", framesReceived, kb)
    }
}
