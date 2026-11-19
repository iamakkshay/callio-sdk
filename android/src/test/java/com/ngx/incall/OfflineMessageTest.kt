package com.ngx.incall

import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** FR-CHAT-03: a message to someone who isn't connected is held by the platform instead of failing. */
class OfflineMessageTest {
    private class FailingTransport(private val code: Int) : SipTransport by StubSipTransport() {
        override suspend fun sendMessage(sipUser: String, text: String?, location: SharedLocation?): String =
            throw InCallException.Network("MESSAGE failed ($code)")
        override suspend fun sendSignal(sipUser: String, json: String) = throw InCallException.Network("MESSAGE failed ($code)")
    }
    private val rider = Contact(name = "rider", sipUser = "1002", displayName = "Rider", userType = UserType.AGENT)

    @Test fun offlinePeerGetsAQueuedMessage() = runTest {
        val queued = mutableListOf<JSONObject>()
        val t = ChatThread(rider, FailingTransport(480)) { queued += it }
        val m = t.send("On my way")
        assertEquals(MessageStatus.QUEUED, m.status)
        assertEquals(1, queued.size)
        assertEquals("text", queued[0].getString("t"))
        assertEquals("On my way", queued[0].getString("text"))
        assertEquals(m.id, queued[0].getString("key"))
        assertEquals(listOf(m), t.messages)
    }

    @Test fun locationIsQueuedToo() = runTest {
        val queued = mutableListOf<JSONObject>()
        val t = ChatThread(rider, FailingTransport(404)) { queued += it }
        val m = t.sendLocation(SharedLocation(24.71, 46.67, "Gate 3"))
        assertEquals(MessageStatus.QUEUED, m.status)
        assertEquals("loc", queued[0].getString("t"))
        assertEquals("Gate 3", queued[0].getJSONObject("loc").getString("label"))
    }

    @Test fun otherFailuresStillFail() = runTest {
        val t = ChatThread(rider, FailingTransport(403)) { fail("must not queue a refused message") }
        try { t.send("hi"); fail("expected an error") } catch (e: InCallException.Network) { assertTrue(e.message!!.contains("403")) }
        assertTrue(t.messages.isEmpty())
    }

    @Test fun photoToSomeoneOfflineIsQueued() = runTest {
        val queued = mutableListOf<JSONObject>()
        val t = ChatThread(rider, FailingTransport(480)) { queued += it }
        val photo = Attachment("abc123", "door.jpg", "image/jpeg", 2048, "/api/attachments/abc123")
        val m = t.sendAttachment(photo)
        assertEquals(MessageStatus.QUEUED, m.status)
        assertEquals("file", queued[0].getString("t"))
        assertEquals("/api/attachments/abc123", queued[0].getJSONObject("attachment").getString("url"))
        assertEquals(photo, m.attachment)
    }

    @Test fun onlyPlatformFilesAreAccepted() {
        assertEquals(null, parseAttachment(JSONObject().put("id", "x").put("url", "https://evil.example/x.jpg")))
        assertEquals("x", parseAttachment(JSONObject().put("id", "x").put("url", "/api/attachments/x"))?.id)
    }
}
