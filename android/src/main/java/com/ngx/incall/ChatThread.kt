package com.ngx.incall

import org.json.JSONObject
import java.util.UUID

/**
 * A 1:1 chat with a contact (FR-CHAT-01/02). Messages are delivered over the same transport as calls
 * (SIP MESSAGE in the reference engine). Obtain one via [InCallClient.thread].
 */
class ChatThread internal constructor(
    val peer: Contact,
    private val transport: SipTransport,
    /** Hands a message to the platform when the peer isn't connected (FR-CHAT-03). */
    private val queue: (suspend (JSONObject) -> Unit)? = null,
) {
    private val _messages = mutableListOf<Message>()
    val messages: List<Message> get() = _messages.toList()

    /** Sends now if the peer is connected; otherwise the platform holds it ([MessageStatus.QUEUED]) until they are. */
    suspend fun send(text: String): Message =
        deliver(Message("", MessageSender.ME, text = text, status = MessageStatus.SENDING)) { transport.sendMessage(peer.sipUser, text, null) }

    suspend fun sendLocation(location: SharedLocation): Message =
        deliver(Message("", MessageSender.ME, location = location, status = MessageStatus.SENDING)) { transport.sendMessage(peer.sipUser, null, location) }

    private suspend fun deliver(draft: Message, direct: suspend () -> String): Message {
        val sent = try {
            draft.copy(id = direct())
        } catch (e: InCallException.Network) {
            val q = queue
            if (q == null || !peerUnreachable(e)) throw e
            val id = "me:" + UUID.randomUUID().toString().substring(0, 10)
            q(wireBody(id, draft.text, draft.location))
            draft.copy(id = id, status = MessageStatus.QUEUED)
        }
        return sent.also { _messages.add(it) }
    }

    /** Send a photo or file already uploaded with [InCallClient.uploadAttachment]. Held for the peer if they're offline. */
    suspend fun sendAttachment(attachment: Attachment): Message {
        val id = "me:" + UUID.randomUUID().toString().substring(0, 10)
        val body = JSONObject().put("key", id).put("t", "file").put("attachment", attachmentJson(attachment))
        val draft = Message(id, MessageSender.ME, attachment = attachment, status = MessageStatus.SENDING)
        val sent = try {
            transport.sendSignal(peer.sipUser, body.toString()); draft
        } catch (e: InCallException.Network) {
            val q = queue
            if (q == null || !peerUnreachable(e)) throw e
            q(body); draft.copy(status = MessageStatus.QUEUED)
        }
        return sent.also { _messages.add(it) }
    }

    suspend fun setTyping(typing: Boolean) = transport.setTyping(typing, peer.sipUser)

    internal fun appendIncoming(id: String, text: String?, location: SharedLocation?, attachment: Attachment? = null) {
        _messages.add(Message(id, MessageSender.PEER, text, location, MessageStatus.DELIVERED, attachment))
    }

    internal fun updateStatus(messageId: String, status: MessageStatus) {
        val i = _messages.indexOfFirst { it.id == messageId }
        if (i >= 0) _messages[i] = _messages[i].copy(status = status)
    }
}

/** 480 / 404 / 408: nobody to deliver to right now (not connected, or the connection went quiet). */
internal fun peerUnreachable(e: InCallException.Network): Boolean =
    Regex("\\((480|404|408)\\)").containsMatchIn(e.message ?: "")

/** The chat body every client sends and understands: {t:"text",text} or {t:"loc",loc:{lat,lng,label}}, with a key. */
internal fun wireBody(key: String, text: String?, location: SharedLocation?): JSONObject {
    val b = JSONObject().put("key", key)
    return if (location != null) b.put("t", "loc").put("loc", JSONObject().put("lat", location.lat).put("lng", location.lng).put("label", location.label))
    else b.put("t", "text").put("text", text ?: "")
}

/** The attachment in a chat message body ({t:"file", attachment:{id,name,type,size,url}}), or null if malformed. */
internal fun parseAttachment(o: JSONObject?): Attachment? {
    if (o == null) return null
    val id = o.optString("id"); val url = o.optString("url")
    if (id.isEmpty() || !url.startsWith("/api/attachments/")) return null   // only the platform's own files
    return Attachment(id, o.optString("name", "file"), o.optString("type", "application/octet-stream"), o.optLong("size"), url)
}

internal fun attachmentJson(a: Attachment): JSONObject =
    JSONObject().put("id", a.id).put("name", a.name).put("type", a.type).put("size", a.size).put("url", a.url)
