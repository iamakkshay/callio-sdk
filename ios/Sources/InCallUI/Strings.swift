import Foundation

/// The prebuilt screens' text in English and Arabic. Pick a language, or override any string.
public struct InCallStrings {
    public enum Language: String { case en, ar }
    public let language: Language
    public var overrides: [String: String]

    public init(language: Language? = nil, overrides: [String: String] = [:]) {
        self.language = language ?? (Locale.preferredLanguages.first?.hasPrefix("ar") == true ? .ar : .en)
        self.overrides = overrides
    }

    public var isRightToLeft: Bool { language == .ar }

    public subscript(_ key: String) -> String {
        overrides[key] ?? Self.table[language]?[key] ?? Self.table[.en]?[key] ?? key
    }

    static let table: [Language: [String: String]] = [
        .en: [
            "calling": "Calling…", "ringing": "Ringing…", "incoming": "Incoming call", "connected": "Connected",
            "onHold": "On hold", "reconnecting": "Reconnecting…", "ended": "Call ended",
            "ended.declined": "Declined", "ended.missed": "Missed", "ended.noAnswer": "No answer", "ended.busy": "Busy",
            "ended.unreachable": "Not reachable",
            "mute": "Mute", "unmute": "Unmute", "speaker": "Speaker", "earpiece": "Phone", "bluetooth": "Bluetooth",
            "audio": "Audio", "hold": "Hold", "resume": "Resume", "keypad": "Keypad", "hideKeypad": "Hide", "end": "End",
            "answer": "Answer", "decline": "Decline",
            "message": "Message", "send": "Send", "shareLocation": "Share location", "typing": "typing…",
            "location": "Location", "openMap": "Open in Maps", "failed": "Not sent",
            "quality.good": "Good connection", "quality.fair": "Fair connection", "quality.poor": "Poor connection",
        ],
        .ar: [
            "calling": "جارٍ الاتصال…", "ringing": "يرن…", "incoming": "مكالمة واردة", "connected": "متصل",
            "onHold": "قيد الانتظار", "reconnecting": "جارٍ إعادة الاتصال…", "ended": "انتهت المكالمة",
            "ended.declined": "مرفوضة", "ended.missed": "فائتة", "ended.noAnswer": "لا يوجد رد", "ended.busy": "مشغول",
            "ended.unreachable": "تعذّر الوصول",
            "mute": "كتم", "unmute": "إلغاء الكتم", "speaker": "مكبّر الصوت", "earpiece": "الهاتف", "bluetooth": "بلوتوث",
            "audio": "الصوت", "hold": "انتظار", "resume": "استئناف", "keypad": "لوحة المفاتيح", "hideKeypad": "إخفاء", "end": "إنهاء",
            "answer": "رد", "decline": "رفض",
            "message": "رسالة", "send": "إرسال", "shareLocation": "مشاركة الموقع", "typing": "يكتب…",
            "location": "الموقع", "openMap": "فتح في الخرائط", "failed": "لم تُرسل",
            "quality.good": "اتصال جيد", "quality.fair": "اتصال متوسط", "quality.poor": "اتصال ضعيف",
        ],
    ]
}
