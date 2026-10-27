package com.ngx.incall.ui

import com.ngx.incall.CallDirection
import com.ngx.incall.CallEndReason
import com.ngx.incall.CallQuality
import com.ngx.incall.CallState

/** What the call screen shows for a call: pure, unit-tested (the same rules as the iOS InCallUI). */
object CallPresentation {
    fun initials(name: String): String {
        val letters = name.split(' ', '-').filter { it.firstOrNull()?.isLetter() == true }.take(2).map { it.first() }.joinToString("")
        return if (letters.isEmpty()) "?" else letters.uppercase()
    }

    fun duration(seconds: Long): String {
        val s = seconds.coerceAtLeast(0)
        return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, (s % 3600) / 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
    }

    fun status(state: CallState, direction: CallDirection, seconds: Long, strings: InCallStrings): String = when (state) {
        is CallState.Initiating -> strings["calling"]
        is CallState.Ringing -> if (direction == CallDirection.INCOMING) strings["incoming"] else strings["ringing"]
        is CallState.Connected -> duration(seconds)
        is CallState.OnHold -> strings["onHold"]
        is CallState.Reconnecting -> strings["reconnecting"]
        is CallState.Ended -> when (state.reason) {
            CallEndReason.ENDED -> strings["ended"]
            CallEndReason.NO_ANSWER -> strings["ended.noAnswer"]
            else -> strings["ended.${state.reason.wire}"]
        }
    }

    fun bars(q: CallQuality?): Int {
        if (q == null) return 3
        q.mos?.let { return if (it >= 4.0) 3 else if (it >= 3.6) 2 else if (it >= 3.1) 1 else 0 }
        val loss = q.lossPct ?: 0.0
        val rtt = q.rttMs ?: 0
        return when { loss > 10 || rtt > 800 -> 0; loss > 5 || rtt > 400 -> 1; loss > 2 || rtt > 250 -> 2; else -> 3 }
    }
}
