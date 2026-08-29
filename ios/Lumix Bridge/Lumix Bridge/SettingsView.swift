//
//  SettingsView.swift
//  Lumix Bridge
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BridgeModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    TextField("Client name", text: $model.clientName)
                        .autocorrectionDisabled()
                    Picker("Name encoding", selection: $model.nameEncoding) {
                        ForEach(PairingCodec.NameEncoding.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                } header: {
                    Text("Identity")
                } footer: {
                    Text("The name shown on the camera's connect prompt. The camera hex-decodes it and renders the result as UTF-16 — sending UTF-8 makes it appear as squares. UTF-16LE is the strong candidate but is not fully confirmed, so it stays changeable.\n\nChanging the name means the camera treats this as a new device: it will prompt on-screen once, and must be armed to accept it.")
                }

                Section("Camera") {
                    if let cam = model.camera {
                        LabeledContent("Model", value: cam.modelNumber)
                        LabeledContent("Name", value: cam.friendlyName)
                        LabeledContent("Firmware", value: cam.firmware)
                        LabeledContent("Address", value: model.snapshotHost)
                        LabeledContent("UDN", value: cam.udn)
                            .font(.caption.monospaced())
                    } else {
                        Text("Not connected").foregroundStyle(.secondary)
                    }
                }

                Section("Behaviour") {
                    Toggle("Haptic feedback", isOn: $model.hapticsEnabled)
                }

                Section {
                    Button("Reconnect") { model.reconnect() }
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                } footer: {
                    Text("The session is held open with a keepalive every 3 seconds — the camera drops an idle session after about 12. Keeping it warm is also what makes the shutter respond in tens of milliseconds instead of seconds.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private extension BridgeModel {
    var snapshotHost: String { snapshot.host ?? "—" }
}

#Preview {
    SettingsView().environment(BridgeModel())
}
