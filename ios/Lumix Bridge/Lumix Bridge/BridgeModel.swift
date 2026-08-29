//
//  BridgeModel.swift
//  Lumix Bridge
//
//  Main-actor view model over LumixSession.
//
//  Responsiveness rule: the shutter must feel instant. A tap flips the UI
//  immediately and fires haptics, then the real camera state reconciles a moment
//  later. Recording start confirms in ~11ms, but stop takes ~1.95s while the clip
//  is finalised — so "stopping" is a visible state rather than a lie.
//

import SwiftUI
import Observation

#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class BridgeModel {

    // MARK: - Published state

    private(set) var snapshot = SessionSnapshot()
    private(set) var lastError: String?

    /// Set the instant the user taps; cleared once the camera agrees.
    private var optimisticRecording: Bool?
    private(set) var isTransitioning = false

    /// What the UI should draw.
    var isRecording: Bool {
        optimisticRecording ?? (snapshot.state?.isRecording ?? false)
    }

    var phase: ConnectionPhase { snapshot.phase }
    var camera: CameraInfo? { snapshot.camera }
    var state: CameraState? { snapshot.state }

    var canRecord: Bool { phase.isReady }

    var statusLine: String {
        switch phase {
        case .ready:
            if let c = camera { return "\(c.modelNumber) · \(snapshot.host ?? "")" }
            return "Ready"
        case .refused, .failed:
            return snapshot.message.isEmpty ? phase.label : snapshot.message
        default:
            return snapshot.message.isEmpty ? phase.label : snapshot.message
        }
    }

    // MARK: - Settings (persisted)

    var clientName: String {
        didSet {
            UserDefaults.standard.set(clientName, forKey: Keys.clientName)
            Task { await session?.setClientName(clientName, encoding: nameEncoding) }
        }
    }

    var nameEncoding: PairingCodec.NameEncoding {
        didSet {
            UserDefaults.standard.set(nameEncoding.rawValue, forKey: Keys.nameEncoding)
            Task { await session?.setClientName(clientName, encoding: nameEncoding) }
        }
    }

    var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: Keys.haptics) }
    }

    private enum Keys {
        static let clientName = "clientName"
        static let nameEncoding = "nameEncoding"
        static let haptics = "hapticsEnabled"
        static let showPreview = "showPreview"
        static let lastHost = "lastHost"
        static let lastUDN = "lastUDN"
    }

    // MARK: - Init

    private var session: LumixSession?

    init() {
        let defaults = UserDefaults.standard
        self.clientName = defaults.string(forKey: Keys.clientName) ?? "S5II Bridge"
        self.nameEncoding = PairingCodec.NameEncoding(
            rawValue: defaults.string(forKey: Keys.nameEncoding) ?? "") ?? .utf16LE
        self.hapticsEnabled = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        self.showPreview = defaults.object(forKey: Keys.showPreview) as? Bool ?? false

        // [weak self] must be on the OUTER closure: putting it only on the inner
        // Task would still capture self strongly here, during init.
        let session = LumixSession(clientName: clientName, nameEncoding: nameEncoding) { [weak self] snap in
            Task { @MainActor in
                self?.apply(snap)
            }
        }
        self.session = session

        let cachedHost = defaults.string(forKey: Keys.lastHost)
        Task { await session.seedCachedHost(cachedHost) }
        logInfo(.app, "Lumix Bridge started")
    }

    // MARK: - Live view
    //
    // Not a preview feature: without `startstream` the camera leaves record mode
    // after ~2s and the shutter stops working. The socket therefore runs whenever
    // we're connected. Decoding is what the toggle actually controls.

    let liveView = LumixLiveView()
    private var streamStarted = false

    var showPreview: Bool {
        didSet {
            UserDefaults.standard.set(showPreview, forKey: Keys.showPreview)
            liveView.decodeFrames = showPreview
            Task { await session?.setLiveViewSize(showPreview ? .vga : .qvga) }
        }
    }

    /// Brings up the UDP socket first, then asks the camera to stream to it, so
    /// the first datagrams aren't answered with ICMP port-unreachable.
    private func startStreamIfNeeded() {
        guard !streamStarted, phase.isReady else { return }
        streamStarted = true
        Task {
            do {
                try liveView.start()
            } catch {
                logError(.session, "live-view socket failed", detail: error.localizedDescription)
            }
            liveView.decodeFrames = showPreview
            let ok = await session?.startStream(port: liveView.port) ?? false
            if !ok {
                streamStarted = false
                logWarn(.session, "stream did not start — record mode will keep lapsing")
            } else {
                await session?.setLiveViewSize(showPreview ? .vga : .qvga)
            }
        }
    }

    private func teardownStream() {
        guard streamStarted else { return }
        streamStarted = false
        Task {
            await session?.stopStream()
            liveView.stop()
        }
    }

    private func apply(_ snap: SessionSnapshot) {
        let wasRecording = snapshot.state?.isRecording
        let wasReady = snapshot.phase.isReady
        snapshot = snap

        if snap.phase.isReady && !wasReady { startStreamIfNeeded() }
        if !snap.phase.isReady && wasReady { teardownStream() }

        // Drop the optimistic override as soon as the camera confirms it.
        if let optimistic = optimisticRecording,
           let actual = snap.state?.isRecording,
           actual == optimistic {
            optimisticRecording = nil
            isTransitioning = false
        }
        if wasRecording != snap.state?.isRecording {
            logDebug(.app, "rec → \(snap.state?.isRecording == true ? "on" : "off")")
        }

        if let host = snap.host { UserDefaults.standard.set(host, forKey: Keys.lastHost) }
        if let udn = snap.camera?.udn { UserDefaults.standard.set(udn, forKey: Keys.lastUDN) }
    }

    // MARK: - Connection

    /// Set by an explicit Disconnect. While true, nothing auto-connects.
    ///
    /// This matters: a Lumix under Wi-Fi remote control disables its physical
    /// buttons, so the body feels "frozen" until the controller lets go. With
    /// auto-connect on launch AND on foreground, the app would re-grab the
    /// camera the moment the user freed it — which is exactly what "I can never
    /// seem to exit it" describes. Releasing has to be sticky.
    private(set) var userDisconnected = false

    var shouldAutoConnect: Bool { !userDisconnected && !phase.isReady }

    func connect() {
        userDisconnected = false
        lastError = nil
        let udn = UserDefaults.standard.string(forKey: Keys.lastUDN)
        Task { await session?.connect(preferredUDN: udn) }
    }

    func reconnect() {
        userDisconnected = false
        Task {
            await session?.reset()
            await session?.connect(preferredUDN: UserDefaults.standard.string(forKey: Keys.lastUDN))
        }
    }

    /// Releases the camera and STAYS released until the user reconnects, so the
    /// body's physical controls come back.
    func disconnect() {
        userDisconnected = true
        teardownStream()
        Task { await session?.disconnect() }
        logInfo(.app, "released camera — physical controls should return")
    }

    /// iOS suspends timers in the background, so the ~12s session always dies
    /// there. Rather than fight it, reconnect on foreground — it costs ~650ms.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if shouldAutoConnect {
                logDebug(.app, "foreground — reconnecting")
                connect()
            } else if userDisconnected {
                logDebug(.app, "foreground — staying released (user disconnected)")
            }
        case .background:
            logDebug(.app, "background — session will lapse")
        default:
            break
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        guard canRecord else { return }
        let target = !isRecording

        // Optimistic: paint the new state now, reconcile when the camera replies.
        optimisticRecording = target
        isTransitioning = true
        haptic(target ? .heavy : .medium)

        Task {
            do {
                if target {
                    try await session?.startRecording()
                } else {
                    try await session?.stopRecording()
                }
            } catch {
                // Roll the optimistic state back and surface why.
                optimisticRecording = nil
                isTransitioning = false
                lastError = error.localizedDescription
                logError(.command, "record \(target ? "start" : "stop") failed",
                         detail: error.localizedDescription)
                haptic(.rigid)
            }
            isTransitioning = false
        }
    }

    // MARK: - Exposure settings
    //
    // Loaded only when the settings sheet is opened or the user pulls to
    // refresh. Never polled — the keepalive stays exactly one getstate every
    // 3s so the shutter always has a live session.

    private(set) var settings = ExposureSettings()
    private(set) var isLoadingSettings = false
    private(set) var settingsError: String?
    private var menuOptions: MenuOptions?

    var settingsAvailable: Bool {
        canRecord && !isRecording && (state?.isInRecordMode ?? false)
    }

    var settingsUnavailableReason: String? {
        if !canRecord { return "Not connected to a camera." }
        if isRecording { return "Locked while recording." }
        if let m = state?.camMode, m != "rec" { return "Camera is in \(m) mode." }
        return nil
    }

    /// One batch of reads. Safe to call repeatedly; it is never automatic.
    func loadSettings(refreshOptions: Bool = false) {
        guard !isLoadingSettings else { return }
        isLoadingSettings = true
        settingsError = nil
        Task {
            do {
                guard let session else { throw LumixError.notReady("no session") }
                settings = try await session.fetchExposureSettings()
                // The option lists rarely change; fetch once per session.
                if menuOptions == nil || refreshOptions {
                    menuOptions = try? await session.menuOptions(forceRefresh: refreshOptions)
                }
            } catch {
                settingsError = error.localizedDescription
                logWarn(.command, "settings load failed", detail: error.localizedDescription)
            }
            isLoadingSettings = false
        }
    }

    /// Selectable values. Shutter and aperture come from the lens limits;
    /// ISO, exposure and WB come from the camera's own enabled menu entries.
    func choices(for key: SettingKey) -> [String] {
        switch key {
        case .shutter: settings.lens?.shutterChoices ?? []
        case .aperture: settings.lens?.apertureChoices ?? []
        default: menuOptions?.choices(for: key) ?? []
        }
    }

    func apply(_ key: SettingKey, value: String) {
        guard !isLoadingSettings else { return }
        isLoadingSettings = true
        settingsError = nil
        haptic(.light)
        Task {
            do {
                guard let session else { throw LumixError.notReady("no session") }
                _ = try await session.setSetting(key, value: value)
                // Changing one exposure value can shift the others, so re-read
                // the whole set rather than patching a single field.
                settings = try await session.fetchExposureSettings()
            } catch {
                settingsError = error.localizedDescription
                haptic(.rigid)
            }
            isLoadingSettings = false
        }
    }

    // MARK: - Developer console

    func runRaw(_ query: String) async -> String {
        do {
            return try await session?.rawCommand(query) ?? "(no session)"
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    // MARK: - Haptics

    #if canImport(UIKit)
    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    #else
    private func haptic(_ style: Int) {}
    #endif
}
