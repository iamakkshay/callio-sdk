package com.ngx.incall

/**
 * The media/signalling transport the client drives. The default implementation is a **stub**: the real
 * one is a port of the reference web engine (public/engine/sip.js) onto a native SIP-over-WSS + WebRTC
 * stack, and must carry over its five recovered media fixes:
 *   1. answerer SDP candidate strip/re-add
 *   2. relay-wait ICE release (no trickle over SIP)
 *   3. TURN transport expansion (UDP/TCP/TLS)
 *   4. single-contact registrar binding
 *   5. register lifecycle + wake handling
 *
 * Everything above this interface (identity, token refresh, events→CDR, history, push registration,
 * the public API) is already implemented; only this needs native WebRTC/SIP work.
 */
internal interface SipTransport {
    var events: SipTransportEvents?

    suspend fun register(session: Session, forceRelay: Boolean)
    suspend fun unregister()

    suspend fun dial(sipUser: String): String      // returns a callId
    suspend fun answer()
    suspend fun decline()
    suspend fun cancel()
    suspend fun hangup()

    suspend fun setMuted(muted: Boolean)
    suspend fun setHold(held: Boolean)
    suspend fun setAudioRoute(route: AudioRoute)
    suspend fun sendDtmf(tone: String)
    suspend fun transfer(sipUser: String)

    suspend fun sendMessage(sipUser: String, text: String?, location: SharedLocation?): String
    suspend fun setTyping(typing: Boolean, sipUser: String)
}

/** Callbacks the transport raises; the client translates these into listener calls. */
internal interface SipTransportEvents {
    fun onRegistrationChanged(state: RegistrationState)
    fun onIncomingCall(sipUser: String, callId: String)
    fun onCallStateChanged(state: CallState, callId: String)
    fun onQualityUpdated(quality: CallQuality, callId: String)
    fun onMessage(sipUser: String, text: String?, location: SharedLocation?, messageId: String)
    fun onMessageStatusChanged(messageId: String, status: MessageStatus)
    fun onFailure(error: InCallException)
    /** An invitation into a 3-way call (room = the conference to dial); [move] = follow the current call there. */
    fun onConferenceInvite(fromSip: String, room: String, move: Boolean, with: List<String>) {}
}

/**
 * Placeholder transport. It drives the client's control flow so the public API is exercisable in
 * tests, but performs no real media. Replace with the native WebRTC/SIP implementation.
 */
internal class StubSipTransport : SipTransport {
    override var events: SipTransportEvents? = null
    private val notImplemented = InCallException.MediaFailed("SIP/WebRTC transport not implemented — port public/engine/sip.js")

    override suspend fun register(session: Session, forceRelay: Boolean) {
        events?.onRegistrationChanged(RegistrationState.CONNECTING)
        throw notImplemented
    }
    override suspend fun unregister() { events?.onRegistrationChanged(RegistrationState.OFFLINE) }

    override suspend fun dial(sipUser: String): String = throw notImplemented
    override suspend fun answer() = throw notImplemented
    override suspend fun decline() {}
    override suspend fun cancel() {}
    override suspend fun hangup() {}

    override suspend fun setMuted(muted: Boolean) {}
    override suspend fun setHold(held: Boolean) {}
    override suspend fun setAudioRoute(route: AudioRoute) {}
    override suspend fun sendDtmf(tone: String) {}
    override suspend fun transfer(sipUser: String) = throw notImplemented

    override suspend fun sendMessage(sipUser: String, text: String?, location: SharedLocation?): String = throw notImplemented
    override suspend fun setTyping(typing: Boolean, sipUser: String) {}
}
