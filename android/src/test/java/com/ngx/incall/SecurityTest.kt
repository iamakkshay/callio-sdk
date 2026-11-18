package com.ngx.incall

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SecurityTest {

    private fun session(turnPassword: String? = "turn-secret-456") = Session(
        tenant = "lab", user = "user-a", userType = UserType.CUSTOMER, features = Features(),
        peers = emptyList(), transferTargets = emptyList(), directory = emptyList(),
        wss = "wss://sip.example.test/ws", realm = "lab", sipUser = "1001", authUser = "1001",
        sipPassword = "sip-secret-123", stun = null, turn = "turn:t.example.test", turnUser = "u",
        turnPassword = turnPassword,
    )

    @Test fun sessionToStringRedactsPasswords() {
        val s = session().toString()
        assertTrue(s, !s.contains("sip-secret-123") && !s.contains("turn-secret-456"))
        assertTrue(s, s.contains("sipPassword=<redacted>") && s.contains("turnPassword=<redacted>") && s.contains("sipUser=1001"))
        assertTrue(session(null).toString().contains("turnPassword=null"))
        assertEquals("sip-secret-123", session().sipPassword)   // still readable by the transports
    }

    private fun rejects(block: () -> Unit): Boolean = try { block(); false } catch (_: IllegalArgumentException) { true }

    @Test fun configRequiresHttpsUnlessInsecureAllowed() {
        assertEquals("https://api.example.test", InCallConfig("https://api.example.test") { "t" }.baseUrl)
        assertTrue("http refused", rejects { InCallConfig("http://10.0.2.2:8080") { "t" } })
        assertTrue("no scheme refused", rejects { InCallConfig("api.example.test") { "t" } })
        assertTrue("ftp refused", rejects { InCallConfig("ftp://x", allowInsecureTransport = true) { "t" } })
        assertEquals("http://10.0.2.2:8080", InCallConfig("http://10.0.2.2:8080", allowInsecureTransport = true) { "t" }.baseUrl)
    }

    @Test fun signallingRequiresWssUnlessInsecureAllowed() {
        TransportSecurity.check("wss://sip.example.test/ws", "wss", "ws", false, "wss")
        assertTrue(rejects { TransportSecurity.check("ws://sip.example.test/ws", "wss", "ws", false, "wss") })
        TransportSecurity.check("ws://localhost:8088/ws", "wss", "ws", true, "wss")
        assertTrue(rejects { TransportSecurity.check("", "wss", "ws", true, "wss") })
    }
}
