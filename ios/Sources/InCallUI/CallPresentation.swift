import Foundation
import InCallSDK

/// What the call screen shows for a call: pure, so it's unit-tested without a UI.
public enum CallPresentation {
    /// "AK" for "Akshay Kumar", "S" for "Sarah"; digits and empty names fall back to "?".
    public static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { $0.first?.isLetter == true }
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// 0:07, 12:34, 1:02:03.
    public static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The status line under the name.
    public static func status(_ state: CallState, direction: CallDirection, seconds: Int, strings: InCallStrings) -> String {
        switch state {
        case .initiating: return strings["calling"]
        case .ringing: return direction == .incoming ? strings["incoming"] : strings["ringing"]
        case .connected: return duration(seconds)
        case .onHold: return strings["onHold"]
        case .reconnecting: return strings["reconnecting"]
        case .ended(let r): return r == .ended ? strings["ended"] : strings["ended.\(r == .noAnswer ? "noAnswer" : r.rawValue)"]
        }
    }

    /// 0–3 bars from the measured quality: MOS when known, otherwise loss and round-trip time.
    public static func bars(_ q: CallQuality?) -> Int {
        guard let q else { return 3 }
        if let mos = q.mos { return mos >= 4.0 ? 3 : mos >= 3.6 ? 2 : mos >= 3.1 ? 1 : 0 }
        let loss = q.lossPct ?? 0, rtt = q.rttMs ?? 0
        if loss > 10 || rtt > 800 { return 0 }
        if loss > 5 || rtt > 400 { return 1 }
        if loss > 2 || rtt > 250 { return 2 }
        return 3
    }

    public static func qualityText(_ bars: Int, strings: InCallStrings) -> String {
        strings[bars >= 3 ? "quality.good" : bars == 2 ? "quality.fair" : "quality.poor"]
    }
}
