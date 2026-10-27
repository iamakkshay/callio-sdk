package com.ngx.incall

/**
 * A 1:1 chat with a contact (FR-CHAT-01/02). Messages are delivered over the same transport as calls
 * (SIP MESSAGE in the reference engine). Obtain one via [InCallClient.thread].
 */
class ChatThread internal constructor(
    val peer: Contact,
    private val transport: SipTransport,
) {
    private val _messages = mutableListOf<Message>()
    val messages: List<Message> get() = _messages.toList()

    suspend fun send(text: String): Message {
        val id = transport.sendMessage(peer.sipUser, text, null)
        return Message(id, MessageSender.ME, text = text, status = MessageStatus.SENDING).also { _messages.add(it) }
    }

    suspend fun sendLocation(location: SharedLocation): Message {
        val id = transport.sendMessage(peer.sipUser, null, location)
        return Message(id, MessageSender.ME, location = location, status = MessageStatus.SENDING).also { _messages.add(it) }
    }

    suspend fun setTyping(typing: Boolean) = transport.setTyping(typing, peer.sipUser)

    internal fun appendIncoming(id: String, text: String?, location: SharedLocation?) {
        _messages.add(Message(id, MessageSender.PEER, text, location, MessageStatus.DELIVERED))
    }

    internal fun updateStatus(messageId: String, status: MessageStatus) {
        val i = _messages.indexOfFirst { it.id == messageId }
        if (i >= 0) _messages[i] = _messages[i].copy(status = status)
    }
}
