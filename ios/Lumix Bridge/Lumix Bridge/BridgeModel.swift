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

    private func apply(_ snap: SessionSnapshot) {
        let wasRecording = snapshot.state?.isRecording
        snapshot = snap

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

    func connect() {
        lastError = nil
        let udn = UserDefaults.standard.string(forKey: Keys.lastUDN)
        Task { await session?.connect(preferredUDN: udn) }
    }

    func reconnect() {
        Task {
            await session?.reset()
            await session?.connect(preferredUDN: UserDefaults.standard.string(forKey: Keys.lastUDN))
        }
    }

    func disconnect() {
        Task { await session?.disconnect() }
    }

    /// iOS suspends timers in the background, so the ~12s session always dies
    /// there. Rather than fight it, reconnect on foreground — it costs ~650ms.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if !self.phase.isReady {
                logDebug(.app, "foreground — reconnecting")
                connect()
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
