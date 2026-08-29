//
//  DevLogView.swift
//  Lumix Bridge
//
//  In-depth developer view: every request and response, plus a raw cam.cgi
//  console for poking the protocol directly from the device.
//

import SwiftUI

struct DevLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BridgeModel.self) private var model
    // Computed rather than a stored default so it is resolved on the main actor.
    private var log: DevLog { DevLog.shared }

    @State private var tab: Tab = .log
    @State private var minLevel: LogLevel = .debug
    @State private var categories: Set<LogCategory> = Set(LogCategory.allCases)
    @State private var searchText = ""
    @State private var expanded: Set<UUID> = []
    @State private var autoScroll = true

    private enum Tab: String, CaseIterable {
        case log = "Log"
        case console = "Console"
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .log: logList
                case .console: RawConsoleView()
                }
            }
            .navigationTitle("Developer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
                if tab == .log {
                    ToolbarItem(placement: .topBarTrailing) { logMenu }
                }
            }
        }
    }

    // MARK: - Log list

    private var entries: [LogEntry] {
        let base = log.filtered(level: minLevel, categories: categories)
        guard !searchText.isEmpty else { return base }
        return base.filter {
            $0.message.localizedCaseInsensitiveContains(searchText)
            || ($0.detail?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List {
                if entries.isEmpty {
                    ContentUnavailableView("No entries",
                                           systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Nothing matches the current filter."))
                }
                ForEach(entries) { entry in
                    LogRow(entry: entry, isExpanded: expanded.contains(entry.id))
                        .id(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard entry.detail?.isEmpty == false else { return }
                            withAnimation(.snappy) {
                                if expanded.contains(entry.id) { expanded.remove(entry.id) }
                                else { expanded.insert(entry.id) }
                            }
                        }
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Filter log")
            .onChange(of: entries.count) { _, _ in
                guard autoScroll, let last = entries.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var logMenu: some View {
        Menu {
            Section("Minimum level") {
                Picker("Level", selection: $minLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { lvl in
                        Label(lvl.label, systemImage: lvl.symbol).tag(lvl)
                    }
                }
            }
            Section("Categories") {
                ForEach(LogCategory.allCases, id: \.self) { cat in
                    Button {
                        if categories.contains(cat) { categories.remove(cat) }
                        else { categories.insert(cat) }
                    } label: {
                        Label(cat.rawValue.capitalized,
                              systemImage: categories.contains(cat) ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
            Section {
                Toggle("Auto-scroll", isOn: $autoScroll)
                ShareLink(item: log.exportText(level: minLevel, categories: categories)) {
                    Label("Export log", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    log.clear()
                    expanded.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
        }
    }
}

// MARK: - Row

private struct LogRow: View {
    let entry: LogEntry
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.timeString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text(entry.category.rawValue)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.18), in: Capsule())
                    .foregroundStyle(color)
                Spacer(minLength: 0)
                if entry.detail?.isEmpty == false {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(entry.message)
                .font(.footnote.monospaced())
                .foregroundStyle(entry.level >= .warning ? color : .primary)
                .textSelection(.enabled)

            if isExpanded, let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.vertical, 3)
    }

    private var color: Color {
        switch entry.level {
        case .debug: .secondary
        case .info: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }
}

// MARK: - Raw console

private struct RawConsoleView: View {
    @Environment(BridgeModel.self) private var model
    @State private var query = "mode=getstate"
    @State private var output = ""
    @State private var running = false

    private let presets = [
        "mode=getstate",
        "mode=getinfo&type=capability",
        "mode=getinfo&type=lens",
        "mode=camcmd&value=recmode",
        "mode=camcmd&value=video_recstart",
        "mode=camcmd&value=video_recstop",
    ]

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField("mode=getstate", text: $query, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.footnote.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    run()
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .disabled(running || query.isEmpty)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { p in
                        Button(p.replacingOccurrences(of: "mode=", with: "")) { query = p }
                            .font(.caption.monospaced())
                            .buttonStyle(.glass)
                    }
                }
            }

            ScrollView {
                Text(output.isEmpty ? "cam.cgi responses appear here." : output)
                    .font(.caption.monospaced())
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Label("Sent with the live session's X-SESSION_ID. Do not send recmode while the camera is recording — it locks the body until the battery is pulled.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .overlay {
            if running { ProgressView().controlSize(.large) }
        }
    }

    private func run() {
        running = true
        let q = query
        Task {
            let result = await model.runRaw(q)
            output = "▸ \(q)\n\n\(result)"
            running = false
        }
    }
}

#Preview {
    DevLogView().environment(BridgeModel())
}
