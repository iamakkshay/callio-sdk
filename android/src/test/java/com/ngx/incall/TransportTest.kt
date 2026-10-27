package com.ngx.incall

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TransportTest {

    @Test fun md5Empty() {
        assertEquals("d41d8cd98f00b204e9800998ecf8427e", DigestAuth.md5Hex(""))
    }

    // Cross-checked RFC-2069 digest vector (verified against the `md5` CLI).
    @Test fun digestResponseNoQop() {
        val ch = DigestAuth.parseChallenge("""Digest realm="testrealm@host.com", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093"""")!!
        assertEquals("testrealm@host.com", ch.realm)
        assertNull(ch.qop)
        val auth = DigestAuth.authorization("Mufasa", "Circle Of Life", "REGISTER", "sip:host.com", ch)
        assertTrue(auth, auth.contains("""response="52ad2b6a7cc0537ab3f10c9feabf754d""""))
        assertTrue(auth.contains("""username="Mufasa""""))
        assertTrue(auth.contains("algorithm=MD5"))
    }

    @Test fun digestResponseWithQop() {
        val ch = DigestAuth.parseChallenge("""Digest realm="lab", nonce="abc123", qop="auth"""")!!
        assertEquals("auth", ch.qop)
        val auth = DigestAuth.authorization("1004", "secret", "INVITE", "sip:1005@lab", ch, cnonce = "deadbeef", nc = "00000001")
        val ha1 = DigestAuth.md5Hex("1004:lab:secret")
        val ha2 = DigestAuth.md5Hex("INVITE:sip:1005@lab")
        val expected = DigestAuth.md5Hex("$ha1:abc123:00000001:deadbeef:auth:$ha2")
        assertTrue(auth, auth.contains("""response="$expected""""))
        assertTrue(auth.contains("qop=auth"))
        assertTrue(auth.contains("""cnonce="deadbeef""""))
    }

    @Test fun parseResponse() {
        val raw = "SIP/2.0 200 OK\r\nVia: SIP/2.0/WS x;branch=z9hG4bK1\r\nCSeq: 2 REGISTER\r\nContact: <sip:1004@host>\r\n\r\n"
        val m = SipMessage.parse(raw)
        assertEquals(200, m.statusCode)
        assertNull(m.method)
        assertEquals("2 REGISTER", m.header("cseq"))
        assertEquals("<sip:1004@host>", m.header("Contact"))
    }

    @Test fun parseRequestWithBody() {
        val raw = "MESSAGE sip:1005@lab SIP/2.0\r\nFrom: <sip:1004@lab>;tag=t1\r\nContent-Type: application/json\r\n\r\n{\"t\":\"text\",\"text\":\"hi\"}"
        val m = SipMessage.parse(raw)
        assertEquals("MESSAGE", m.method)
        assertNull(m.statusCode)
        assertEquals("{\"t\":\"text\",\"text\":\"hi\"}", m.body)
    }

    @Test fun buildRequestHasContentLength() {
        val out = SipMessage.buildRequest("MESSAGE", "sip:1005@lab", listOf("To" to "<sip:1005@lab>"), "hello")
        assertTrue(out.startsWith("MESSAGE sip:1005@lab SIP/2.0\r\n"))
        assertTrue(out.contains("Content-Length: 5\r\n"))
        assertTrue(out.endsWith("\r\n\r\nhello"))
    }
}
