//
//  CameraSettings.swift
//  Lumix Bridge
//
//  Exposure settings: shutter, aperture, ISO, exposure compensation, white
//  balance. All confirmed writable on DC-S5M2 fw 3.61.
//
//  Two encodings are in play:
//    shtrspeed  "1792/256"  ->  denominator = 2^(n/256)      1792 -> 1/125
//    focal      "1024/256"  ->  f-number    = 2^(n/512)      1024 -> f/4.0
//    exposure   "1/3", "0", "-2/3"          (EV, thirds)
//    iso        "auto" or "800"
//    whitebalance  token, e.g. "auto", "cloudy"
//
//  A full stop is 256 in both numerators; a third of a stop is 256/3.
//

import Foundation

public enum SettingKey: String, Sendable, CaseIterable {
    case shutter = "shtrspeed"
    case aperture = "focal"
    case iso = "iso"
    case exposure = "exposure"
    case whiteBalance = "whitebalance"

    public var title: String {
        switch self {
        case .shutter: "Shutter"
        case .aperture: "Aperture"
        case .iso: "ISO"
        case .exposure: "Exposure"
        case .whiteBalance: "White Balance"
        }
    }

    public var symbol: String {
        switch self {
        case .shutter: "camera.aperture"
        case .aperture: "circle.circle"
        case .iso: "circle.lefthalf.filled"
        case .exposure: "plusminus.circle"
        case .whiteBalance: "thermometer.sun"
        }
    }

    /// Menu-id prefix in `getinfo&type=curmenu`, where it differs from the
    /// get/setsetting type. ISO is the notable one: `sensitivity` in the menu.
    var menuPrefix: String? {
        switch self {
        case .iso: "sensitivity"
        case .whiteBalance: "whitebalance"
        case .exposure: "exposure"
        case .shutter, .aperture: nil     // continuous, bounded by the lens
        }
    }
}

// MARK: - Value formatting

public enum SettingFormat {

    /// Numerator out of a "n/256" pair.
    static func numerator(_ raw: String) -> Int? {
        Int(raw.split(separator: "/").first.map(String.init) ?? "")
    }

    private static let standardShutter: [Double] = [
        8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1300, 1000, 800, 640,
        500, 400, 320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 20,
        15, 13, 10, 8, 6, 5, 4, 3, 2
    ]

    private static let standardAperture: [Double] = [
        1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5,
        5.0, 5.6, 6.3, 7.1, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 25, 29, 32
    ]

    private static func nearest(_ v: Double, in table: [Double]) -> Double {
        table.min { abs($0 - v) < abs($1 - v) } ?? v
    }

    /// "1792/256" -> "1/125"; values <= 0 are exposures of a second or longer.
    public static func shutterLabel(_ raw: String) -> String {
        guard let n = numerator(raw) else { return raw }
        if n > 0 {
            let denom = pow(2.0, Double(n) / 256.0)
            let snapped = nearest(denom, in: standardShutter)
            return "1/\(Int(snapped.rounded()))"
        }
        let seconds = pow(2.0, Double(-n) / 256.0)
        return seconds < 10
            ? String(format: "%.1f\"", seconds)
            : String(format: "%.0f\"", seconds)
    }

    /// "1024/256" -> "f/4"
    public static func apertureLabel(_ raw: String) -> String {
        guard let n = numerator(raw) else { return raw }
        let f = nearest(pow(2.0, Double(n) / 512.0), in: standardAperture)
        return f < 10
            ? "f/\(String(format: "%.1f", f).replacingOccurrences(of: ".0", with: ""))"
            : "f/\(Int(f.rounded()))"
    }

    public static func isoLabel(_ raw: String) -> String {
        raw == "auto" ? "AUTO" : raw
    }

    /// "1/3" -> "+1/3 EV", "0" -> "0 EV"
    public static func exposureLabel(_ raw: String) -> String {
        if raw == "0" { return "0 EV" }
        return raw.hasPrefix("-") ? "\(raw) EV" : "+\(raw) EV"
    }

    public static func label(for key: SettingKey, raw: String) -> String {
        switch key {
        case .shutter: shutterLabel(raw)
        case .aperture: apertureLabel(raw)
        case .iso: isoLabel(raw)
        case .exposure: exposureLabel(raw)
        case .whiteBalance: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Candidate "n/256" values across a range, on the camera's 1/3-stop grid.
    static func thirdStopValues(from lo: Int, to hi: Int) -> [String] {
        guard hi > lo else { return [] }
        let step = 256.0 / 3.0
        var out: [String] = []
        var v = Double(lo)
        while v <= Double(hi) + 1 {
            out.append("\(Int(v.rounded()))/256")
            v += step
        }
        return out
    }
}

// MARK: - Lens limits

/// `getinfo&type=lens` replies with CSV, not XML:
/// ok,2304/256,935/256,3584/256,1195/256,0,off,60,20,on,...,LUMIX S 20-60/F3.5-5.6,...
public struct LensInfo: Sendable, Equatable {
    /// Numerators of the "n/256" encodings.
    public var maxApertureValue: Int      // largest f-number  (e.g. f/22)
    public var minApertureValue: Int      // smallest f-number (e.g. f/3.5)
    public var fastestShutterValue: Int
    public var slowestShutterValue: Int
    public var name: String

    public init?(csv: String) {
        let f = csv.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count > 14, f[0] == "ok",
              let maxA = SettingFormat.numerator(f[1]),
              let minA = SettingFormat.numerator(f[2]),
              let fastS = SettingFormat.numerator(f[3]),
              let slowS = SettingFormat.numerator(f[4]) else { return nil }
        self.maxApertureValue = maxA
        self.minApertureValue = minA
        self.fastestShutterValue = fastS
        self.slowestShutterValue = slowS
        self.name = f[14]
    }

    var apertureChoices: [String] {
        SettingFormat.thirdStopValues(from: minApertureValue, to: maxApertureValue)
    }
    var shutterChoices: [String] {
        SettingFormat.thirdStopValues(from: slowestShutterValue, to: fastestShutterValue)
    }
}

// MARK: - Menu options

/// `getinfo&type=curmenu` is a flat list of
/// `<item id="menu_item_id_X" enable="yes|no" value="…">`.
/// The parent carries the current value; children `menu_item_id_X_<token>`
/// are the options, and only `enable="yes"` ones can be selected right now.
public struct MenuOptions: Sendable {
    private var enabledByPrefix: [String: [String]] = [:]

    public init(curmenu xml: String) {
        var acc: [String: [String]] = [:]
        let pattern = #"<item\s+([^>]*?)/?>"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = xml as NSString

        for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: m.range(at: 1))
            guard let id = Self.attr("id", in: attrs),
                  Self.attr("enable", in: attrs) == "yes",
                  id.hasPrefix("menu_item_id_") else { continue }
            let body = String(id.dropFirst("menu_item_id_".count))
            // Attribute the token to its longest known parent prefix.
            for prefix in Self.knownPrefixes where body.hasPrefix(prefix + "_") {
                let token = String(body.dropFirst(prefix.count + 1))
                guard !token.isEmpty, !token.contains("filter") else { continue }
                acc[prefix, default: []].append(token)
            }
        }
        self.enabledByPrefix = acc
    }

    private static let knownPrefixes = ["sensitivity", "whitebalance", "exposure"]

    private static func attr(_ name: String, in s: String) -> String? {
        guard let r = s.range(of: "\(name)=\"") else { return nil }
        let rest = s[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Selectable raw values for a key, already in set-setting form.
    public func choices(for key: SettingKey) -> [String] {
        guard let prefix = key.menuPrefix, let tokens = enabledByPrefix[prefix] else {
            return []
        }
        switch key {
        case .exposure:
            // Menu ids encode EV as m8_3 / p1_3 / 0 -> "-8/3", "1/3", "0".
            return tokens.compactMap { t in
                if t == "0" { return "0" }
                let sign = t.hasPrefix("m") ? "-" : (t.hasPrefix("p") ? "" : nil)
                guard let sign else { return nil }
                let body = String(t.dropFirst()).replacingOccurrences(of: "_", with: "/")
                return sign + (body.contains("/") ? body : body + "/1")
            }
            .sorted { evValue($0) < evValue($1) }
        case .iso:
            // Drop the extended "L…" duplicates; keep auto first, then ascending.
            let cleaned = tokens.filter { !$0.hasPrefix("L") && $0 != "i_iso" }
            let numbers = cleaned.compactMap(Int.init).sorted().map(String.init)
            return (cleaned.contains("auto") ? ["auto"] : []) + numbers
        default:
            return tokens
        }
    }

    private func evValue(_ s: String) -> Double {
        let neg = s.hasPrefix("-")
        let body = neg ? String(s.dropFirst()) : s
        let parts = body.split(separator: "/").compactMap { Double($0) }
        let v = parts.count == 2 ? parts[0] / parts[1] : (parts.first ?? 0)
        return neg ? -v : v
    }
}

// MARK: - Snapshot of everything the settings sheet shows

public struct ExposureSettings: Sendable, Equatable {
    public var values: [String: String] = [:]     // SettingKey.rawValue -> raw value
    public var lens: LensInfo?
    public var fetchedAt: Date?

    public func raw(_ key: SettingKey) -> String? { values[key.rawValue] }

    public func label(_ key: SettingKey) -> String {
        guard let r = raw(key) else { return "—" }
        return SettingFormat.label(for: key, raw: r)
    }
}
