//
//  CamCGI.swift
//  Lumix Bridge
//
//  Wire format for Panasonic's /cam.cgi. Two response shapes exist:
//    - XML   <camrply><result>ok</result>...</camrply>   (almost everything)
//    - CSV   ok,S5M2-XXXX,remote,open,<SESSION_ID>       (accctrl only)
//
//  Confirmed against DC-S5M2 firmware 3.61.
//

import Foundation

// MARK: - Errors

public enum LumixError: LocalizedError, Sendable {
    /// The camera explicitly refused pairing. NEVER retry this — see PairState.
    case refused
    case notArmed(String)
    case cameraError(String)
    case notFound
    case notReady(String)
    case transport(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .refused:
            "Camera refused the connection. Arm it with Wi-Fi Function → New Connection → Remote Shooting & View, then try again."
        case .notArmed(let s):
            "Camera is not accepting connections (\(s)). Re-arm it on the body."
        case .cameraError(let s):
            "Camera returned \(s)."
        case .notFound:
            "No Lumix camera found on this network."
        case .notReady(let s):
            "Not connected (\(s))."
        case .transport(let s):
            "Network error: \(s)."
        case .badResponse(let s):
            "Unexpected reply: \(s)."
        }
    }
}

// MARK: - accctrl handshake states

/// Result of a `req_acc_e` poll.
public enum PairState: Sendable, Equatable {
    /// Granted. Carries the session id.
    case granted(String)
    /// Camera is showing a confirmation dialog and waiting on a human.
    case promptingOperator
    /// Camera is deciding silently — this client name is already registered.
    case decidingSilently
    /// REFUSED. The body is not armed. Retrying trips the "invalid login"
    /// lockout, which requires a physical power cycle.
    case refused
    /// A different pending request holds the single request slot.
    case othersRequesting
    /// Stale slot, or the body has left remote-control mode.
    case critical
    case unknown(String)

    init(csv: String) {
        let parts = csv.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let head = parts.first else { self = .unknown(csv); return }

        switch head {
        case "ok":
            if let sid = parts.last, parts.count >= 2, !sid.isEmpty {
                self = .granted(sid)
            } else {
                self = .unknown(csv)
            }
        case "ok_under_research":         self = .promptingOperator
        case "ok_under_research_no_msg":  self = .decidingSilently
        case "err_user_refused":          self = .refused
        case "err_others_requesting":     self = .othersRequesting
        default:
            // XML error bodies also arrive here (e.g. err_critical).
            if csv.contains("err_critical") { self = .critical }
            else { self = .unknown(head) }
        }
    }
}

// MARK: - Parsing

public enum CamCGI {

    /// Extracts `<result>…</result>`.
    public static func result(_ body: String) -> String? {
        firstMatch(in: body, tag: "result")
    }

    public static func isOK(_ body: String) -> Bool { result(body) == "ok" }

    /// Parses the `<state>` block into a flat dictionary.
    public static func state(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        // Matches simple <tag>value</tag> pairs with no nested elements.
        let pattern = #"<([A-Za-z_][\w-]*)>([^<>]*)</\1>"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = body as NSString
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1))
            let val = ns.substring(with: m.range(at: 2))
            out[key] = val
        }
        return out
    }

    static func firstMatch(in body: String, tag: String) -> String? {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tag))>(.*?)</\(NSRegularExpression.escapedPattern(for: tag))>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = body as NSString
        guard let m = re.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Pairing codec

public enum PairingCodec {
    /// How the client name is encoded into `value2`.
    ///
    /// The camera hex-decodes `value2` and renders the result. Sending hex of
    /// UTF-8 makes the on-screen prompt show CJK squares — proof: "s5iictl" as
    /// UTF-8 is 73 35 69 69 63 74 6c, which read as UTF-16LE is 0x3573 0x6969
    /// 0x7463, i.e. CJK. UTF-16LE is therefore the strong candidate but has NOT
    /// been cleanly confirmed on-camera yet, so it stays switchable.
    public enum NameEncoding: String, Sendable, CaseIterable {
        case utf16LE = "utf-16-le"
        case utf16BE = "utf-16-be"
        case utf8 = "utf-8"

        func data(_ s: String) -> Data {
            switch self {
            case .utf8:
                return Data(s.utf8)
            case .utf16LE:
                return Data(s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            case .utf16BE:
                return Data(s.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
            }
        }
    }

    /// `value` — the camera's UDN as plain ASCII hex. Byte-compared, never shown.
    public static func encodeUDN(_ udn: String) -> String {
        Data(udn.utf8).hexString
    }

    /// `value2` — the client name. This is what the camera displays.
    public static func encodeName(_ name: String, as encoding: NameEncoding) -> String {
        encoding.data(name).hexString
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Camera description (UPnP ddd)

public struct CameraInfo: Sendable, Equatable, Codable {
    public var friendlyName: String
    public var manufacturer: String
    public var modelName: String
    public var modelNumber: String
    public var serialNumber: String
    /// Without the `uuid:` prefix.
    public var udn: String
    public var firmware: String

    /// Parses the XML served at `:60606/Lumix/Server0/ddd`.
    /// Returns nil unless this is genuinely a Panasonic device with a UDN —
    /// important, because a hung camera still accepts TCP on 60606.
    public init?(ddd xml: String) {
        func tag(_ t: String) -> String { CamCGI.firstMatch(in: xml, tag: t) ?? "" }

        let rawUDN = tag("UDN")
        let maker = tag("manufacturer")
        guard !rawUDN.isEmpty, maker.lowercased().contains("panasonic") else { return nil }

        self.friendlyName = tag("friendlyName")
        self.manufacturer = maker
        self.modelName = tag("modelName")
        self.modelNumber = tag("modelNumber")
        self.serialNumber = tag("serialNumber")
        self.udn = rawUDN.hasPrefix("uuid:") ? String(rawUDN.dropFirst(5)) : rawUDN
        self.firmware = tag("pana:X_FirmVersion")
    }
}

// MARK: - Live camera state

public struct CameraState: Sendable, Equatable {
    public var isRecording: Bool
    public var camMode: String          // "rec" | "play"
    public var battery: String
    public var sdCardStatus: String
    public var videoRemainingSeconds: Int?
    public var temperature: String
    public var raw: [String: String]

    public init(dict: [String: String]) {
        self.raw = dict
        self.isRecording = dict["rec"] == "on"
        self.camMode = dict["cammode"] ?? "?"
        self.battery = dict["batt"] ?? "?"
        self.sdCardStatus = dict["sdcardstatus"] ?? "?"
        self.videoRemainingSeconds = dict["video_remaincapacity"].flatMap { Int($0) }
        self.temperature = dict["temperature"] ?? "?"
    }

    public var isInRecordMode: Bool { camMode == "rec" }

    public var remainingTimeString: String? {
        guard let s = videoRemainingSeconds else { return nil }
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
