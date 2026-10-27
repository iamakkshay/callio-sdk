package com.ngx.incall.ui

import java.util.Locale

/** The prebuilt screens' text in English and Arabic. Pick a language, or override any string. */
class InCallStrings(language: String? = null, private val overrides: Map<String, String> = emptyMap()) {
    val language: String = language ?: if (Locale.getDefault().language == "ar") "ar" else "en"
    val isRightToLeft get() = language == "ar"

    operator fun get(key: String): String = overrides[key] ?: TABLE[language]?.get(key) ?: TABLE["en"]?.get(key) ?: key

    companion object {
        val TABLE = mapOf(
            "en" to mapOf(
                "calling" to "Calling…", "ringing" to "Ringing…", "incoming" to "Incoming call", "connected" to "Connected",
                "onHold" to "On hold", "reconnecting" to "Reconnecting…", "ended" to "Call ended",
                "ended.declined" to "Declined", "ended.missed" to "Missed", "ended.noAnswer" to "No answer", "ended.busy" to "Busy",
                "ended.unreachable" to "Not reachable",
                "mute" to "Mute", "unmute" to "Unmute", "speaker" to "Speaker", "earpiece" to "Phone", "bluetooth" to "Bluetooth",
                "audio" to "Audio", "hold" to "Hold", "resume" to "Resume", "keypad" to "Keypad", "hideKeypad" to "Hide", "end" to "End",
                "answer" to "Answer", "decline" to "Decline",
                "message" to "Message", "send" to "Send", "shareLocation" to "Share location", "location" to "Location",
                "failed" to "Not sent",
                "quality.good" to "Good connection", "quality.fair" to "Fair connection", "quality.poor" to "Poor connection",
            ),
            "ar" to mapOf(
                "calling" to "جارٍ الاتصال…", "ringing" to "يرن…", "incoming" to "مكالمة واردة", "connected" to "متصل",
                "onHold" to "قيد الانتظار", "reconnecting" to "جارٍ إعادة الاتصال…", "ended" to "انتهت المكالمة",
                "ended.declined" to "مرفوضة", "ended.missed" to "فائتة", "ended.noAnswer" to "لا يوجد رد", "ended.busy" to "مشغول",
                "ended.unreachable" to "تعذّر الوصول",
                "mute" to "كتم", "unmute" to "إلغاء الكتم", "speaker" to "مكبّر الصوت", "earpiece" to "الهاتف", "bluetooth" to "بلوتوث",
                "audio" to "الصوت", "hold" to "انتظار", "resume" to "استئناف", "keypad" to "لوحة المفاتيح", "hideKeypad" to "إخفاء", "end" to "إنهاء",
                "answer" to "رد", "decline" to "رفض",
                "message" to "رسالة", "send" to "إرسال", "shareLocation" to "مشاركة الموقع", "location" to "الموقع",
                "failed" to "لم تُرسل",
                "quality.good" to "اتصال جيد", "quality.fair" to "اتصال متوسط", "quality.poor" to "اتصال ضعيف",
            ),
        )
    }
}
