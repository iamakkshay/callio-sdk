package com.ngx.incall

/**
 * A single call. Methods delegate to the transport; state changes arrive back through the client's
 * listener (contract §3). Create one via [InCallClient.dial] or receive it in
 * [InCallListener.onIncomingCall].
 */
class Call internal constructor(
    val id: String,
    val peer: Contact,
    val direction: CallDirection,
    state: CallState,
    private val transport: SipTransport,
) {
    var state: CallState = state
        internal set
    var quality: CallQuality? = null
        internal set
    var isMuted: Boolean = false
        private set
    var isOnHold: Boolean = false
        private set

    private val startedAt = System.currentTimeMillis()

    /** Seconds since the call object was created. */
    val durationSec: Long get() = (System.currentTimeMillis() - startedAt) / 1000

    suspend fun answer() = transport.answer()
    suspend fun hangup() = transport.hangup()
    suspend fun decline() = transport.decline()
    suspend fun cancel() = transport.cancel()

    suspend fun setMuted(muted: Boolean) { isMuted = muted; transport.setMuted(muted) }
    suspend fun setHold(held: Boolean) { isOnHold = held; transport.setHold(held) }
    suspend fun setAudioRoute(route: AudioRoute) { audio?.set(route); transport.setAudioRoute(route) }
    internal var audio: AudioRouter? = null
    suspend fun sendDtmf(tone: String) = transport.sendDtmf(tone)
    suspend fun transfer(contact: Contact) = transport.transfer(contact.sipUser)
}
