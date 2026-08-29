//
//  ContentView.swift
//  Lumix Bridge
//

import SwiftUI

struct ContentView: View {
    @Environment(BridgeModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var showLogs = false
    @State private var showSettings = false
    @State private var showExposure = false
    @Namespace private var glass

    var body: some View {
        NavigationStack {
            ZStack {
                backdrop
                VStack(spacing: 28) {
                    StatusCard(namespace: glass)
                    Spacer(minLength: 0)
                    RecordButton()
                    Spacer(minLength: 0)
                    TelemetryRow(namespace: glass)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .navigationTitle("Lumix Bridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showExposure = true } label: {
                        Label("Exposure", systemImage: "camera.aperture")
                    }
                    .disabled(!model.canRecord)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showLogs = true } label: {
                        Label("Developer log", systemImage: "terminal")
                    }
                }
            }
            .sheet(isPresented: $showLogs) { DevLogView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showExposure) { CameraSettingsView() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
        .task {
            if !model.phase.isReady { model.connect() }
        }
    }

    /// Recording tints the whole backdrop — peripheral-vision feedback so you
    /// can tell the camera is rolling without reading anything.
    private var backdrop: some View {
        LinearGradient(
            colors: model.isRecording
                ? [.red.opacity(0.35), .black.opacity(0.85)]
                : [Color.accentColor.opacity(0.18), .black.opacity(0.9)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.45), value: model.isRecording)
    }
}

// MARK: - Record button

private struct RecordButton: View {
    @Environment(BridgeModel.self) private var model

    private var enabled: Bool { model.canRecord }

    var body: some View {
        Button {
            model.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(.clear)
                    .frame(width: 232, height: 232)

                // Circle -> rounded square is the universal "rolling" affordance.
                RoundedRectangle(cornerRadius: model.isRecording ? 32 : 88,
                                 style: .continuous)
                    .fill(enabled ? Color.red : Color.gray)
                    .frame(width: model.isRecording ? 96 : 176,
                           height: model.isRecording ? 96 : 176)
                    .shadow(color: .red.opacity(model.isRecording ? 0.55 : 0), radius: 28)

                if model.isTransitioning {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .glassEffect(
            .regular.tint(model.isRecording ? .red.opacity(0.5) : .clear).interactive(),
            in: Circle()
        )
        .animation(.bouncy(duration: 0.35), value: model.isRecording)
        .animation(.smooth, value: enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(model.isRecording ? "Stop recording" : "Start recording")
        .accessibilityAddTraits(.isButton)
        .overlay(alignment: .bottom) {
            Text(caption)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .offset(y: 44)
                .contentTransition(.opacity)
        }
    }

    private var caption: String {
        if !enabled { return model.phase.label }
        if model.isTransitioning && !model.isRecording { return "Stopping…" }
        return model.isRecording ? "Recording" : "Tap to record"
    }
}

// MARK: - Status

private struct StatusCard: View {
    @Environment(BridgeModel.self) private var model
    let namespace: Namespace.ID

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: dotColor.opacity(0.8), radius: 5)
                    Text(model.camera?.friendlyName ?? "No camera")
                        .font(.headline)
                    Spacer()
                    if case .searching = model.phase { ProgressView().controlSize(.small) }
                    if case .connecting = model.phase { ProgressView().controlSize(.small) }
                }

                Text(model.statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                if needsAction {
                    Button("Retry") { model.reconnect() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .glassEffectID("status", in: namespace)
        }
    }

    private var needsAction: Bool {
        switch model.phase {
        case .refused, .failed, .disconnected: true
        default: false
        }
    }

    private var dotColor: Color {
        switch model.phase {
        case .ready: model.isRecording ? .red : .green
        case .searching, .connecting: .yellow
        case .refused, .failed: .orange
        case .disconnected: .gray
        }
    }
}

// MARK: - Telemetry

private struct TelemetryRow: View {
    @Environment(BridgeModel.self) private var model
    let namespace: Namespace.ID

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                chip("battery.100", model.state?.battery ?? "—", "Battery")
                chip("clock", model.state?.remainingTimeString ?? "—", "Remaining")
                chip("sdcard", sdLabel, "Card")
            }
        }
        .padding(.bottom, 8)
    }

    private var sdLabel: String {
        switch model.state?.sdCardStatus {
        case "write_enable": "OK"
        case .none: "—"
        case .some(let s): s
        }
    }

    private func chip(_ symbol: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

#Preview {
    ContentView()
        .environment(BridgeModel())
}
