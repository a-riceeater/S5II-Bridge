//
//  LumixSession.swift
//  Lumix Bridge
//
//  Owns the camera session for the lifetime of the app.
//
//  The S5II expects ONE controller that stays connected. Anything that pairs,
//  fires a command and goes away leaves the camera showing "connection failed",
//  after which it drops out of remote mode and starts accepting TCP on :60606
//  while never answering HTTP. So this object connects once and holds on.
//
//  Holding the session is also what makes the shutter fast: a warm session gives
//  recstart in 12-70ms, while a cold one costs ~6.5s because the play->rec
//  transition (~5s) is paid per session.
//

import Foundation

public enum ConnectionPhase: Sendable, Equatable {
    case disconnected
    case searching
    case connecting
    case ready
    /// Terminal until the operator re-arms the body. Never auto-retried.
    case refused(String)
    case failed(String)

    public var isReady: Bool { self == .ready }

    public var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .searching:    "Searching…"
        case .connecting:   "Connecting…"
        case .ready:        "Ready"
        case .refused:      "Refused"
        case .failed:       "Error"
        }
    }
}

public struct SessionSnapshot: Sendable, Equatable {
    public var phase: ConnectionPhase = .disconnected
    public var camera: CameraInfo?
    public var host: String?
    public var sessionID: String?
    public var state: CameraState?
    public var message: String = ""
}

public actor LumixSession {

    // Timings, all measured on DC-S5M2 fw 3.61.
    static let sessionIdleTimeout: TimeInterval = 12.0   // dies at ~12s of silence
    static let keepaliveInterval: TimeInterval = 3.0     // comfortable margin
    static let recSettleTimeout: TimeInterval = 6.0      // recstop takes ~1.95s
    static let recModeTimeout: TimeInterval = 20.0       // play->rec takes ~5s
    static let promptWindow: TimeInterval = 240.0        // a human must walk over
    /// Consecutive missed keepalives before declaring the session dead. The
    /// camera routinely misses one right after a record command.
    static let keepaliveFailureLimit = 3

    private let transport: LumixTransport
    private let discovery: LumixDiscovery

    public private(set) var clientName: String
    public private(set) var nameEncoding: PairingCodec.NameEncoding

    private var snapshot = SessionSnapshot()
    private var keepaliveTask: Task<Void, Never>?
    private var commandInFlight = false
    private var keepaliveFailures = 0
    /// Latched when the camera rejects a command as busy. Blocks all further
    /// commands until a human clears it. See command().
    private var faulted: String?

    private let onChange: @Sendable (SessionSnapshot) -> Void

    public init(clientName: String = "S5II Bridge",
                nameEncoding: PairingCodec.NameEncoding = .utf16LE,
                onChange: @escaping @Sendable (SessionSnapshot) -> Void) {
        let transport = LumixTransport()
        self.transport = transport
        self.discovery = LumixDiscovery(transport: transport)
        self.clientName = clientName
        self.nameEncoding = nameEncoding
        self.onChange = onChange
    }

    // MARK: - Snapshot plumbing

    private func publish() { onChange(snapshot) }

    private func setPhase(_ phase: ConnectionPhase, _ message: String = "") {
        snapshot.phase = phase
        snapshot.message = message
        publish()
    }

    public func currentSnapshot() -> SessionSnapshot { snapshot }

    public func setClientName(_ name: String, encoding: PairingCodec.NameEncoding) {
        clientName = name
        nameEncoding = encoding
    }

    public func seedCachedHost(_ host: String?) async {
        await discovery.seedCache(host: host)
    }

    // MARK: - Connect

    /// Full bring-up: find the camera, pair, and leave it in record mode.
    public func connect(preferredUDN: String? = nil) async {
        guard snapshot.phase != .searching, snapshot.phase != .connecting else { return }

        // A latched fault must survive reconnect attempts, otherwise a
        // supervisor loop retries err_busy forever — which is the cascade that
        // locks the camera. Only clearFault()/reset() may lift this.
        if let fault = faulted {
            setPhase(.failed("Camera busy"),
                     "The camera reported \(fault) and is not accepting commands. "
                     + "Check the camera body, then tap Retry.")
            return
        }

        setPhase(.searching)
        guard let found = await discovery.find(udn: preferredUDN) else {
            setPhase(.failed("No camera found"),
                     "No Lumix camera answered on this network. If the camera is on, it may have dropped out of remote mode — re-arm it on the body.")
            return
        }

        snapshot.camera = found.info
        snapshot.host = found.host
        setPhase(.connecting)

        do {
            let sid = try await pair(host: found.host, udn: found.info.udn)
            snapshot.sessionID = sid
            try await ensureRecordMode(host: found.host, sessionID: sid)
            setPhase(.ready)
            startKeepalive()
            logInfo(.session, "READY — session \(sid)")
        } catch LumixError.refused {
            snapshot.sessionID = nil
            setPhase(.refused("Camera refused"),
                     "The camera is not armed to accept a new device. On the body: MENU → Setup → IN/OUT → LAN/Wi-Fi → Wi-Fi Function → New Connection → Remote Shooting & View.")
            logError(.pairing, "REFUSED — not retrying (repeated refusals trip the camera's lockout)")
        } catch {
            snapshot.sessionID = nil
            setPhase(.failed(error.localizedDescription), error.localizedDescription)
            logError(.session, "connect failed", detail: error.localizedDescription)
        }
    }

    public func disconnect() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        snapshot.sessionID = nil
        snapshot.state = nil
        setPhase(.disconnected)
        logInfo(.session, "disconnected")
    }

    public func clearFault() {
        faulted = nil
        logInfo(.session, "fault cleared by user")
    }

    public func isFaulted() -> Bool { faulted != nil }

    /// Clears a `refused`/`failed` phase so the user can retry after re-arming.
    public func reset() {
        faulted = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        snapshot = SessionSnapshot()
        publish()
    }

    // MARK: - Pairing

    /// req_acc_g arms a single pending request slot; req_acc_e polls it.
    /// Re-sending an identical req_acc_e polls the SAME request — sending a
    /// different one, or re-arming, replaces it and orphans any acceptance the
    /// operator has already given.
    private func pair(host: String, udn: String) async throws -> String {
        let value = PairingCodec.encodeUDN(udn)
        let value2 = PairingCodec.encodeName(clientName, as: nameEncoding)
        logInfo(.pairing, "pairing as \"\(clientName)\" [\(nameEncoding.rawValue)]",
                detail: "value2=\(value2)")

        _ = try? await transport.cgi(host: host, query: "mode=accctrl&type=req_acc_g",
                                     timeout: 6, category: .pairing)

        var deadline = Date().addingTimeInterval(30)
        var rearms = 0
        var prompted = false

        while Date() < deadline {
            let body = try await transport.cgi(
                host: host,
                query: "mode=accctrl&type=req_acc_e&value=\(value)&value2=\(value2)",
                timeout: 8, category: .pairing)

            switch PairState(csv: body.trimmingCharacters(in: .whitespacesAndNewlines)) {
            case .granted(let sid):
                logInfo(.pairing, "granted — session \(sid)")
                // Confirm the connection by registering our display name.
                _ = try? await transport.cgi(
                    host: host,
                    query: "mode=setsetting&type=device_name&value=\(clientName.urlQueryEncoded)",
                    sessionID: sid, timeout: 6, category: .pairing)
                return sid

            case .promptingOperator:
                if !prompted {
                    prompted = true
                    // A dialog is up and a human has to walk to the camera.
                    // Extend generously and NEVER re-arm while it's displayed.
                    deadline = Date().addingTimeInterval(Self.promptWindow)
                    setPhase(.connecting,
                             "Confirm the connection on the camera screen.")
                    logWarn(.pairing, "camera is prompting the operator — waiting up to \(Int(Self.promptWindow))s")
                }
                try? await Task.sleep(for: .milliseconds(500))

            case .decidingSilently:
                try? await Task.sleep(for: .milliseconds(300))

            case .refused:
                // Hard stop. Each refusal feeds a counter that ends in the
                // camera's "invalid login" lockout and a forced power cycle.
                throw LumixError.refused

            case .othersRequesting, .critical, .unknown:
                rearms += 1
                guard rearms <= 3 else {
                    throw LumixError.notArmed("stuck after \(rearms) re-arms")
                }
                logWarn(.pairing, "stale request slot — re-arming (\(rearms)/3)")
                try? await Task.sleep(for: .seconds(1))
                _ = try? await transport.cgi(host: host,
                                             query: "mode=accctrl&type=req_acc_g",
                                             timeout: 6, category: .pairing)
            }
        }
        throw LumixError.notArmed("pairing not granted in time")
    }

    // MARK: - Record mode

    /// After every fresh pairing the camera reports cammode=play, and
    /// video_recstart returns err_critical until it's switched. The transition
    /// takes ~5s and the HTTP server stops answering during part of it.
    ///
    /// SAFETY: `recmode` must NEVER be sent while the camera is recording — it
    /// hard-locks the body (black screen, recoverable only by pulling the
    /// battery). So this only switches on a POSITIVELY confirmed
    /// `cammode=play` + `rec=off`. An unreadable state is treated as "do not
    /// touch", never as "probably in playback".
    private func ensureRecordMode(host: String, sessionID: String) async throws {
        if let fault = faulted {
            throw LumixError.cameraError("blocked: camera reported \(fault)")
        }
        // Read state with retries: the camera is briefly unresponsive right
        // after a record command, and a single nil here must not be mistaken
        // for "in playback".
        var observed: CameraState?
        for attempt in 1...4 {
            if let s = await fetchState(host: host, sessionID: sessionID) {
                observed = s
                break
            }
            logDebug(.session, "state unreadable while checking mode (\(attempt)/4)")
            try? await Task.sleep(for: .milliseconds(400))
        }

        guard let state = observed else {
            // Never guess. Guessing here is what sends recmode mid-recording.
            throw LumixError.cameraError(
                "could not read camera state; refusing to change mode blindly")
        }
        snapshot.state = state

        if state.isRecording {
            // Recording implies record mode. Switching now would lock the body.
            logWarn(.session, "camera is RECORDING — not touching mode")
            return
        }
        if state.isInRecordMode {
            return
        }

        logInfo(.session, "camera is in playback — switching to record (~5s)")
        setPhase(.connecting, "Switching camera to record mode…")

        // The reply code from recmode is NOT trustworthy: it frequently returns
        // err_critical while the switch actually succeeds (confirmed — cammode
        // read "rec" two seconds after an err_critical reply). So the result is
        // deliberately ignored and only the observed state is believed. Failing
        // on the reply code here is what stopped the client connecting at all.
        _ = try? await transport.cgi(host: host, query: "mode=camcmd&value=recmode",
                                     sessionID: sessionID, timeout: 12,
                                     category: .command)

        let deadline = Date().addingTimeInterval(Self.recModeTimeout)
        while Date() < deadline {
            if let s = await fetchState(host: host, sessionID: sessionID), s.isInRecordMode {
                snapshot.state = s
                logInfo(.session, "record mode active")
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        throw LumixError.cameraError("camera did not enter record mode")
    }

    // MARK: - State

    private func fetchState(host: String, sessionID: String,
                            quiet: Bool = true) async -> CameraState? {
        guard let body = try? await transport.cgi(host: host, query: "mode=getstate",
                                                  sessionID: sessionID, timeout: 4,
                                                  category: .session),
              CamCGI.isOK(body) else { return nil }
        return CameraState(dict: CamCGI.state(body))
    }

    // MARK: - Keepalive

    /// The session dies after ~12s of silence. getstate doubles as the state
    /// feed, so keeping it warm costs nothing extra (~400 bytes every 3s).
    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LumixSession.keepaliveInterval))
                guard let self else { return }
                await self.keepaliveTick()
            }
        }
    }

    private func keepaliveTick() async {
        guard snapshot.phase.isReady,
              let host = snapshot.host,
              let sid = snapshot.sessionID,
              !commandInFlight else { return }

        if let s = await fetchState(host: host, sessionID: sid) {
            keepaliveFailures = 0
            if snapshot.state != s {
                snapshot.state = s
                publish()
            }
            // The camera drops out of record mode ~2s after the stream stops.
            // Re-issuing startstream restores it and is safe; recmode is NOT
            // (it locks the body if it lands while recording), so only the
            // stream is used for this recovery.
            if s.camMode != "rec", !s.isRecording, let port = streamPort {
                logWarn(.session, "cammode=\(s.camMode) — restarting stream to hold record mode")
                await startStream(port: port)
            }
            return
        }

        // A single miss means nothing. The camera stops answering for a beat
        // right after a record command, and reacting to that by tearing down and
        // reconnecting is what previously led to a mode switch mid-recording.
        keepaliveFailures += 1
        logDebug(.session, "keepalive miss \(keepaliveFailures)/\(Self.keepaliveFailureLimit)")
        guard keepaliveFailures >= Self.keepaliveFailureLimit else { return }

        // Believed-recording is the hard gate: never rebuild the session out
        // from under an active take. Keep pinging instead.
        if snapshot.state?.isRecording == true {
            logWarn(.session, "session looks lost but camera is RECORDING — holding, not reconnecting")
            return
        }

        logWarn(.session, "keepalive lost the session — reconnecting")
        keepaliveFailures = 0
        keepaliveTask?.cancel()
        keepaliveTask = nil
        snapshot.sessionID = nil
        setPhase(.disconnected)
        await connect(preferredUDN: snapshot.camera?.udn)
    }

    // MARK: - Commands

    /// Sends a command, transparently re-pairing once if the session lapsed.
    ///
    /// CIRCUIT BREAKER: `err_busy` means the camera cannot accept the command in
    /// its current state. Sending anything further into that state is what
    /// escalates into a hard lock (black screen, battery pull) — observed twice.
    /// So the first `err_busy` latches a fault and every subsequent command is
    /// refused locally until a human clears it. Nothing is retried, nothing is
    /// re-paired, and no mode change is attempted.
    @discardableResult
    private func command(_ query: String) async throws -> String {
        if let fault = faulted {
            throw LumixError.cameraError(
                "blocked: camera reported \(fault) and is not accepting commands. "
                + "Check the body, then clear the fault to resume.")
        }
        guard let host = snapshot.host, let sid = snapshot.sessionID else {
            throw LumixError.notReady(snapshot.phase.label)
        }
        let body = try await transport.cgi(host: host, query: query,
                                           sessionID: sid, timeout: 8)

        if CamCGI.result(body) == "err_busy" {
            faulted = "err_busy"
            setPhase(.failed("Camera busy"),
                     "The camera rejected a command as busy. Further commands are blocked to avoid locking it up — check the camera body, then tap Retry.")
            logError(.command, "err_busy — LATCHING FAULT, no further commands will be sent",
                     detail: query)
            throw LumixError.cameraError("err_busy")
        }

        guard CamCGI.result(body) == "err_critical" else { return body }

        logWarn(.session, "err_critical — session expired, re-pairing")
        let newSID = try await pair(host: host, udn: snapshot.camera?.udn ?? "")
        snapshot.sessionID = newSID
        // Deliberately NOT ensureRecordMode: that would put recmode on the
        // shutter path, and we cannot know from here whether the camera is
        // already rolling. Re-establish the stream instead — it restores record
        // mode when the camera is idle and is harmless when it is not.
        if let port = streamPort {
            await startStream(port: port)
            try? await Task.sleep(for: .milliseconds(600))
        }
        publish()
        return try await transport.cgi(host: host, query: query,
                                       sessionID: newSID, timeout: 8)
    }

    /// <rec> is not a synchronous ack: it flips to "on" in ~11ms but takes
    /// ~1.95s to reach "off" while the clip is finalised. Poll until it settles,
    /// otherwise a toggle reads a stale value and does the opposite.
    @discardableResult
    private func awaitRecording(_ expected: Bool) async -> Bool {
        guard let host = snapshot.host, let sid = snapshot.sessionID else { return false }
        let deadline = Date().addingTimeInterval(Self.recSettleTimeout)
        while Date() < deadline {
            if let s = await fetchState(host: host, sessionID: sid) {
                snapshot.state = s
                publish()
                if s.isRecording == expected { return true }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        logWarn(.command, "recording state did not settle to \(expected)")
        return false
    }

    public func startRecording() async throws {
        commandInFlight = true
        defer { commandInFlight = false }

        // The camera can slip back to playback on its own. Restore it with the
        // STREAM, never with recmode.
        //
        // recmode must never appear on the shutter path. The cached cammode can
        // be up to one keepalive old, so it may read "play" while the camera is
        // in fact already rolling — and recmode landing on a rolling camera
        // freezes the body. startstream is harmless in every state, so drift
        // recovery uses only that.
        if let mode = snapshot.state?.camMode, mode != "rec",
           snapshot.state?.isRecording != true,
           let port = streamPort {
            logWarn(.command, "camera is in \(mode) — restarting stream (not recmode)")
            await startStream(port: port)
            try? await Task.sleep(for: .milliseconds(600))
        }

        let body = try await command("mode=camcmd&value=video_recstart")
        guard CamCGI.isOK(body) else {
            throw LumixError.cameraError(CamCGI.result(body) ?? "unknown")
        }
        logInfo(.command, "record START")
        await awaitRecording(true)
    }

    public func stopRecording() async throws {
        commandInFlight = true
        defer { commandInFlight = false }
        let body = try await command("mode=camcmd&value=video_recstop")
        guard CamCGI.isOK(body) else {
            throw LumixError.cameraError(CamCGI.result(body) ?? "unknown")
        }
        logInfo(.command, "record STOP")
        await awaitRecording(false)   // ~2s while the clip is finalised
    }

    /// Reads fresh state first — the cached keepalive sample may be up to 3s old.
    public func toggleRecording() async throws {
        guard let host = snapshot.host, let sid = snapshot.sessionID else {
            throw LumixError.notReady(snapshot.phase.label)
        }
        let live = await fetchState(host: host, sessionID: sid)
        if let live { snapshot.state = live; publish() }
        if live?.isRecording == true {
            try await stopRecording()
        } else {
            try await startRecording()
        }
    }

    // MARK: - Live-view stream (required to hold record mode)
    //
    // Measured: with keepalive alone the camera leaves cammode=rec after ~2s and
    // video_recstart then fails. With startstream running it holds indefinitely.
    // So this is part of the shutter path, not a preview feature.

    private var streamPort: UInt16?

    @discardableResult
    public func startStream(port: UInt16) async -> Bool {
        guard let host = snapshot.host, let sid = snapshot.sessionID,
              faulted == nil else { return false }
        guard let body = try? await transport.cgi(
            host: host, query: "mode=startstream&value=\(port)",
            sessionID: sid, timeout: 8, category: .session),
              CamCGI.isOK(body) else {
            logWarn(.session, "startstream failed — record mode will lapse in ~2s")
            return false
        }
        streamPort = port
        logInfo(.session, "stream started on udp/\(port) — holding record mode")
        return true
    }

    public func stopStream() async {
        guard let host = snapshot.host, let sid = snapshot.sessionID,
              streamPort != nil else { return }
        _ = try? await transport.cgi(host: host, query: "mode=stopstream",
                                     sessionID: sid, timeout: 6, category: .session)
        streamPort = nil
        logInfo(.session, "stream stopped")
    }

    public func setLiveViewSize(_ size: LiveViewSize) async {
        guard let host = snapshot.host, let sid = snapshot.sessionID,
              faulted == nil else { return }
        _ = try? await transport.cgi(
            host: host, query: "mode=setsetting&type=liveviewsize&value=\(size.rawValue)",
            sessionID: sid, timeout: 6, category: .session)
        logInfo(.session, "liveviewsize = \(size.rawValue)")
    }

    // MARK: - Exposure settings
    //
    // Strictly on demand. NOTHING here runs on a timer and nothing is added to
    // the keepalive: holding the session for the shutter is the priority, so
    // settings traffic only happens when the user opens the sheet or taps a
    // value. `curmenu` is ~66KB, so it is fetched at most once per session.

    private var cachedMenu: MenuOptions?

    /// Settings are unreadable in playback and must never be touched mid-take.
    private func requireSettingsAccess() throws -> (host: String, sid: String) {
        if let fault = faulted {
            throw LumixError.cameraError("blocked: camera reported \(fault)")
        }
        guard snapshot.phase.isReady,
              let host = snapshot.host,
              let sid = snapshot.sessionID else {
            throw LumixError.notReady(snapshot.phase.label)
        }
        if snapshot.state?.isRecording == true {
            throw LumixError.cameraError("settings are locked while recording")
        }
        if let mode = snapshot.state?.camMode, mode != "rec" {
            throw LumixError.cameraError("camera is in \(mode) mode")
        }
        return (host, sid)
    }

    /// One batch: five getsetting calls plus the lens limits. ~1.5KB total.
    public func fetchExposureSettings() async throws -> ExposureSettings {
        let (host, sid) = try requireSettingsAccess()
        commandInFlight = true
        defer { commandInFlight = false }

        var out = ExposureSettings()
        for key in SettingKey.allCases {
            guard let body = try? await transport.cgi(
                host: host, query: "mode=getsetting&type=\(key.rawValue)",
                sessionID: sid, timeout: 6, category: .command) else { continue }
            // <settingvalue iso="auto"></settingvalue>
            if let v = Self.settingValue(body, key: key.rawValue) {
                out.values[key.rawValue] = v
            }
        }

        if let lensBody = try? await transport.cgi(
            host: host, query: "mode=getinfo&type=lens",
            sessionID: sid, timeout: 8, category: .command) {
            out.lens = LensInfo(csv: lensBody)     // CSV, not XML
        }

        out.fetchedAt = Date()
        logInfo(.command, "settings read: " + SettingKey.allCases
            .map { "\($0.rawValue)=\(out.raw($0) ?? "-")" }.joined(separator: " "))
        return out
    }

    /// Option lists. Cached for the session — this is the only large request.
    public func menuOptions(forceRefresh: Bool = false) async throws -> MenuOptions {
        if let cachedMenu, !forceRefresh { return cachedMenu }
        let (host, sid) = try requireSettingsAccess()
        commandInFlight = true
        defer { commandInFlight = false }

        let body = try await transport.cgi(host: host, query: "mode=getinfo&type=curmenu",
                                           sessionID: sid, timeout: 15, category: .command)
        let menu = MenuOptions(curmenu: body)
        cachedMenu = menu
        logInfo(.command, "curmenu cached (\(body.count) bytes)")
        return menu
    }

    /// Writes one setting and reads it straight back. Returns the readback.
    @discardableResult
    public func setSetting(_ key: SettingKey, value: String) async throws -> String {
        let (host, sid) = try requireSettingsAccess()
        commandInFlight = true
        defer { commandInFlight = false }

        let body = try await transport.cgi(
            host: host,
            query: "mode=setsetting&type=\(key.rawValue)&value=\(value.urlPathEncoded)",
            sessionID: sid, timeout: 8, category: .command)

        guard CamCGI.isOK(body) else {
            let err = CamCGI.result(body) ?? "unknown"
            logWarn(.command, "set \(key.rawValue)=\(value) rejected: \(err)")
            throw LumixError.cameraError(err)
        }

        try? await Task.sleep(for: .milliseconds(400))
        let readBody = try await transport.cgi(
            host: host, query: "mode=getsetting&type=\(key.rawValue)",
            sessionID: sid, timeout: 6, category: .command)
        let now = Self.settingValue(readBody, key: key.rawValue) ?? value
        logInfo(.command, "set \(key.rawValue) = \(now)")
        // Changing one exposure value can shift the others; the caller re-reads.
        return now
    }

    /// Pulls `key="value"` out of `<settingvalue key="value">`.
    private static func settingValue(_ body: String, key: String) -> String? {
        guard let r = body.range(of: "\(key)=\"") else { return nil }
        let rest = body[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Raw passthrough for the developer console.
    public func rawCommand(_ query: String) async throws -> String {
        guard let host = snapshot.host else { throw LumixError.notReady("no camera") }
        return try await transport.cgi(host: host, query: query,
                                       sessionID: snapshot.sessionID, timeout: 8)
    }
}

extension String {
    var urlQueryEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }

    /// Setting values such as "1792/256" and "-2/3" are sent with the slash and
    /// sign literal — that is the form the camera accepted under test.
    var urlPathEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-_.")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
