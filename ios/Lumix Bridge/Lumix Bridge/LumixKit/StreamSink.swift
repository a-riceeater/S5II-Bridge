//
//  StreamSink.swift
//  Lumix Bridge
//
//  NOT a live-view feature. There is no preview anywhere in this app.
//
//  The camera will not STAY in record mode without a stream running. Measured on
//  DC-S5M2 fw 3.61:
//
//      recmode, keepalive only     -> cammode falls back to play (2s / ~8s)
//      recmode, then startstream   -> held cammode=rec for 45s+
//      startstream alone from play -> stays in play (never enters rec)
//
//  So `startstream` is part of the shutter path. This class exists only to give
//  the camera somewhere to send those datagrams: it binds the UDP port, drains
//  it, and throws every byte away. Nothing is decoded and nothing is displayed.
//  The frame size is set to the smallest the camera offers.
//
//  Not @MainActor: the Network framework delivers on its own queue, and hopping
//  to the main actor to discard bytes would be pure waste.
//

import Foundation
import Network

public enum LiveViewSize: String, Sendable, CaseIterable {
    /// Smallest first — we never look at the frames, so smallest is always right.
    case qvga, vga, low, standard, fine
}

public final class StreamSink: @unchecked Sendable {

    public let port: UInt16

    private let queue = DispatchQueue(label: "lumix.stream.sink", qos: .utility)
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var _datagrams = 0
    private var _bytes = 0

    public init(port: UInt16 = 49199) {
        self.port = port
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listener != nil
    }

    /// Counters, for the developer log only.
    public var stats: (datagrams: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_datagrams, _bytes)
    }

    /// Bind BEFORE asking the camera to stream, so the first datagrams are not
    /// answered with ICMP port-unreachable.
    public func start() throws {
        lock.lock()
        let alreadyRunning = listener != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LumixError.transport("bad stream port \(port)")
        }

        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.lock.lock()
            self.connections.append(connection)
            self.lock.unlock()
            self.drain(connection)
        }
        listener.start(queue: queue)

        lock.lock()
        self.listener = listener
        lock.unlock()
        logInfo(.session, "stream sink listening on udp/\(port) (frames discarded)")
    }

    public func stop() {
        lock.lock()
        let l = listener
        let conns = connections
        listener = nil
        connections = []
        lock.unlock()

        l?.cancel()
        conns.forEach { $0.cancel() }
        logInfo(.session, "stream sink closed")
    }

    /// Read and discard. Nonisolated so it can recurse straight from the
    /// Network framework's callback without hopping actors.
    private func drain(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self._datagrams += 1
                self._bytes += data.count
                self.lock.unlock()
            }
            if error == nil {
                self.drain(connection)
            }
        }
    }
}
