//
//  DevLog.swift
//  Lumix Bridge
//
//  In-memory developer log. Every camera request/response lands here so the
//  protocol can be debugged from the device without a cable.
//

import Foundation
import Observation

public enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case debug = 0, info, warning, error

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }

    public var symbol: String {
        switch self {
        case .debug: "ladybug"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

public enum LogCategory: String, Sendable, CaseIterable {
    case discovery = "discovery"
    case pairing = "pairing"
    case session = "session"
    case command = "command"
    case http = "http"
    case app = "app"
}

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    /// Optional raw payload (full HTTP body), kept out of the summary line.
    public let detail: String?

    public var timeString: String {
        Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// Observable ring buffer. `log` is nonisolated so the networking actors can call
/// it without awaiting the main actor; entries are ordered by their captured
/// timestamp rather than by delivery order.
@MainActor
@Observable
public final class DevLog {
    public static let shared = DevLog()

    public private(set) var entries: [LogEntry] = []
    public var minimumLevel: LogLevel = .debug

    /// Bounded so a long session can't grow without limit.
    private let capacity = 2000

    private init() {}

    nonisolated public func log(_ level: LogLevel,
                                _ category: LogCategory,
                                _ message: String,
                                detail: String? = nil) {
        let entry = LogEntry(date: Date(), level: level, category: category,
                             message: message, detail: detail)
        Task { @MainActor in
            DevLog.shared.append(entry)
        }
    }

    private func append(_ entry: LogEntry) {
        // Delivery can reorder slightly because each call hops to the main actor,
        // so insert by timestamp instead of blindly appending.
        if let last = entries.last, last.date > entry.date {
            let idx = entries.lastIndex { $0.date <= entry.date }.map { $0 + 1 } ?? 0
            entries.insert(entry, at: idx)
        } else {
            entries.append(entry)
        }
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    public func clear() { entries.removeAll() }

    public func filtered(level: LogLevel, categories: Set<LogCategory>) -> [LogEntry] {
        entries.filter { $0.level >= level && categories.contains($0.category) }
    }

    /// Plain-text dump for sharing / pasting into a bug report.
    public func exportText(level: LogLevel = .debug,
                           categories: Set<LogCategory> = Set(LogCategory.allCases)) -> String {
        filtered(level: level, categories: categories).map { e in
            var line = "\(e.timeString) [\(e.level.label)] [\(e.category.rawValue)] \(e.message)"
            if let d = e.detail, !d.isEmpty { line += "\n    \(d)" }
            return line
        }.joined(separator: "\n")
    }
}

// Convenience shorthands used across LumixKit.
@inline(__always) func logDebug(_ c: LogCategory, _ m: String, detail: String? = nil) {
    DevLog.shared.log(.debug, c, m, detail: detail)
}
@inline(__always) func logInfo(_ c: LogCategory, _ m: String, detail: String? = nil) {
    DevLog.shared.log(.info, c, m, detail: detail)
}
@inline(__always) func logWarn(_ c: LogCategory, _ m: String, detail: String? = nil) {
    DevLog.shared.log(.warning, c, m, detail: detail)
}
@inline(__always) func logError(_ c: LogCategory, _ m: String, detail: String? = nil) {
    DevLog.shared.log(.error, c, m, detail: detail)
}
