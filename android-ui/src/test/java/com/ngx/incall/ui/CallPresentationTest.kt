package com.ngx.incall.ui

import com.ngx.incall.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CallPresentationTest {
    private val en = InCallStrings("en")
    private val ar = InCallStrings("ar")

    @Test fun initials() {
        assertEquals("AK", CallPresentation.initials("Akshay Kumar"))
        assertEquals("S", CallPresentation.initials("sarah"))
        assertEquals("?", CallPresentation.initials("1002"))
        assertEquals("فا", CallPresentation.initials("فاطمة الزهراء"))
    }

    @Test fun durations() {
        assertEquals("0:07", CallPresentation.duration(7))
        assertEquals("12:34", CallPresentation.duration(754))
        assertEquals("1:02:03", CallPresentation.duration(3723))
    }

    @Test fun statusLines() {
        assertEquals("Incoming call", CallPresentation.status(CallState.Ringing, CallDirection.INCOMING, 0, en))
        assertEquals("1:05", CallPresentation.status(CallState.Connected, CallDirection.OUTGOING, 65, en))
        assertEquals("No answer", CallPresentation.status(CallState.Ended(CallEndReason.NO_ANSWER), CallDirection.OUTGOING, 0, en))
        assertEquals("مشغول", CallPresentation.status(CallState.Ended(CallEndReason.BUSY), CallDirection.OUTGOING, 0, ar))
        assertTrue(ar.isRightToLeft)
    }

    @Test fun qualityBars() {
        assertEquals(3, CallPresentation.bars(null))
        assertEquals(2, CallPresentation.bars(CallQuality(rttMs = 300, jitterMs = 20, lossPct = 1.0)))
        assertEquals(0, CallPresentation.bars(CallQuality(rttMs = 900, jitterMs = 40, lossPct = 12.0)))
    }
}
