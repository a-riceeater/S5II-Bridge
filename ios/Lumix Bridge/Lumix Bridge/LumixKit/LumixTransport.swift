//
//  LumixTransport.swift
//  Lumix Bridge
//
//  Thin HTTP layer for /cam.cgi. Every request gets its own timeout: the camera
//  goes fully unresponsive for seconds at a time during a play->rec switch and
//  when the body has dropped out of remote mode, so a shared long timeout would
//  stall the UI.
//

import Foundation

public actor LumixTransport {

    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        // The camera serves identical URLs with changing bodies; never cache.
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.httpShouldSetCookies = false
        cfg.httpAdditionalHeaders = ["Accept": "*/*"]
        // One camera, one connection.
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    /// Raw GET returning the body as text.
    public func get(_ url: URL,
                    sessionID: String? = nil,
                    timeout: TimeInterval = 8,
                    category: LogCategory = .http,
                    quiet: Bool = false) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.httpMethod = "GET"
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "X-SESSION_ID") }

        let started = Date()
        do {
            let (data, response) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let body = String(decoding: data, as: UTF8.self)

            guard let http = response as? HTTPURLResponse else {
                throw LumixError.badResponse("non-HTTP response")
            }
            if !quiet {
                logDebug(category,
                         "\(http.statusCode) \(ms)ms  \(url.query ?? url.path)",
                         detail: body.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw LumixError.badResponse("HTTP \(http.statusCode)")
            }
            return body
        } catch let e as LumixError {
            throw e
        } catch {
            if !quiet {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                logWarn(category, "FAILED \(ms)ms  \(url.query ?? url.path)",
                        detail: error.localizedDescription)
            }
            throw LumixError.transport(error.localizedDescription)
        }
    }

    /// `GET http://<host>/cam.cgi?<query>`
    public func cgi(host: String,
                    query: String,
                    sessionID: String? = nil,
                    timeout: TimeInterval = 8,
                    category: LogCategory = .command) async throws -> String {
        guard let url = URL(string: "http://\(host)/cam.cgi?\(query)") else {
            throw LumixError.badResponse("bad URL for query \(query)")
        }
        return try await get(url, sessionID: sessionID, timeout: timeout, category: category)
    }

    /// Fetches the UPnP description, trying both known paths.
    /// `quiet` suppresses logging so a 254-host sweep doesn't flood the log.
    public func describe(host: String,
                         timeout: TimeInterval = 2.5,
                         quiet: Bool = false) async -> CameraInfo? {
        for path in ["/Lumix/Server0/ddd", "/Server0/ddd"] {
            guard let url = URL(string: "http://\(host):60606\(path)") else { continue }
            guard let xml = try? await get(url, timeout: timeout,
                                           category: .discovery, quiet: quiet),
                  let info = CameraInfo(ddd: xml) else { continue }
            return info
        }
        return nil
    }
}
