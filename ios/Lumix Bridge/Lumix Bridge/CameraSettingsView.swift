//
//  CameraSettingsView.swift
//  Lumix Bridge
//
//  Exposure controls. Everything here is on demand: values load when the sheet
//  opens and on an explicit refresh, never on a timer. The keepalive that holds
//  the shutter session is untouched.
//

import SwiftUI

struct CameraSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BridgeModel.self) private var model

    @State private var editing: SettingKey?

    var body: some View {
        NavigationStack {
            Group {
                if let reason = model.settingsUnavailableReason {
                    ContentUnavailableView {
                        Label("Settings unavailable", systemImage: "camera.badge.ellipsis")
                    } description: {
                        Text(reason)
                    } actions: {
                        if !model.isRecording {
                            Button("Try again") { model.loadSettings() }
                                .buttonStyle(.glassProminent)
                        }
                    }
                } else {
                    content
                }
            }
            .navigationTitle("Exposure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.loadSettings(refreshOptions: true)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoadingSettings)
                }
            }
            .sheet(item: $editing) { key in
                SettingPickerView(key: key)
            }
        }
        .task {
            // Only fires when the sheet appears.
            if model.settings.fetchedAt == nil { model.loadSettings() }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let err = model.settingsError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 10) {
                        ForEach(SettingKey.allCases, id: \.self) { key in
                            row(key)
                        }
                    }
                }

                if let lens = model.settings.lens {
                    Text(lens.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                Text("Values are read when you open this sheet or tap Refresh. Nothing polls in the background — the connection stays reserved for the shutter.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }
            .padding(16)
        }
        .overlay {
            if model.isLoadingSettings && model.settings.fetchedAt == nil {
                ProgressView().controlSize(.large)
            }
        }
    }

    private func row(_ key: SettingKey) -> some View {
        let hasChoices = !model.choices(for: key).isEmpty
        return Button {
            guard hasChoices else { return }
            editing = key
        } label: {
            HStack(spacing: 14) {
                Image(systemName: key.symbol)
                    .font(.system(size: 17))
                    .frame(width: 28)
                    .foregroundStyle(.secondary)
                Text(key.title)
                    .font(.body)
                Spacer()
                Text(model.settings.label(key))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if hasChoices {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasChoices || model.isLoadingSettings)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(hasChoices ? 1 : 0.55)
    }
}

// MARK: - Picker

private struct SettingPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BridgeModel.self) private var model
    let key: SettingKey

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.choices(for: key), id: \.self) { value in
                    Button {
                        model.apply(key, value: value)
                        dismiss()
                    } label: {
                        HStack {
                            Text(SettingFormat.label(for: key, raw: value))
                                .monospacedDigit()
                            Spacer()
                            if value == model.settings.raw(key) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(key.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension SettingKey: Identifiable {
    public var id: String { rawValue }
}

#Preview {
    CameraSettingsView().environment(BridgeModel())
}
