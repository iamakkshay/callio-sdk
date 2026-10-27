package com.ngx.incall

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PushServiceTest {
    @Test fun parsesIncomingCallPush() {
        val data = mapOf("notification" to
            """{"type":"incoming_call","callId":"c1","tenant":"lab","from":{"displayName":"Vineet","userType":"agent"}}""")
        val push = PushService.parse(data)
        assertEquals("c1", push?.callId)
        assertEquals("Vineet", push?.fromDisplayName)
        assertEquals("lab", push?.tenant)
    }

    @Test fun ignoresNonCallPush() {
        assertNull(PushService.parse(mapOf("notification" to """{"type":"something_else"}""")))
        assertNull(PushService.parse(emptyMap()))
    }

    @Test fun endReasonRoundTrips() {
        assertEquals(CallEndReason.NO_ANSWER, CallEndReason.from("no-answer"))
        assertEquals(CallEndReason.ENDED, CallEndReason.from("unknown"))
    }
}
