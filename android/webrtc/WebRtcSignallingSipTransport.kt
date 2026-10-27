// WebRtcSignallingSipTransport — SignallingSipTransport + real WebRTC calls. Compiled when the build includes
// webrtc/ (see build.gradle.kts). InCallClient's public constructor picks it up automatically when present.
package com.ngx.incall

import android.content.Context
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.UUID

internal class WebRtcSignallingSipTransport(private val context: Context) : SipTransport {
    override var events: SipTransportEvents? = null

    private var client: SipWsClient? = null
    private var session: Session? = null
    private var forceRelay = false
    private var media: WebRtcMedia? = null
    private var pendingOffer: String? = null
    private var currentCallId: String? = null

    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private fun onMain(block: () -> Unit) { main.post(block) }

    override suspend fun register(session: Session, forceRelay: Boolean) {
        this.session = session; this.forceRelay = forceRelay
        onMain { events?.onRegistrationChanged(RegistrationState.CONNECTING) }
        val c = SipWsClient(SipWsClient.Config(session.wss, session.realm, session.sipUser, session.authUser, session.sipPassword))
        c.onChatMessage = { fromSip, body -> handleInbound(fromSip, body) }
        c.onIncomingInvite = { fromSip, offer, callId ->
            pendingOffer = offer; currentCallId = callId
            onMain { events?.onIncomingCall(fromSip, callId) }
        }
        c.onBye = { _ -> media?.close(); media = null; val id = currentCallId ?: ""; onMain { events?.onCallStateChanged(CallState.Ended(CallEndReason.ENDED), id) } }
        c.onCancel = { callId -> pendingOffer = null; onMain { events?.onCallStateChanged(CallState.Ended(CallEndReason.MISSED), callId) } }
        c.onReOffer = { offer -> withContext(Dispatchers.Default) { (media ?: throw InCallException.MediaFailed("no call")).reAnswer(offer) } }
        c.onRemoteHold = { held -> val id = currentCallId ?: ""; onMain { events?.onCallStateChanged(if (held) CallState.OnHold else CallState.Connected, id) } }
        client = c
        c.connect()
        c.register()
        onMain { events?.onRegistrationChanged(RegistrationState.REGISTERED) }
    }

    override suspend fun unregister() { media?.close(); media = null; client?.unregister(); client?.close(); client = null }

    // --- Calls (WebRTC) ---

    override suspend fun dial(sipUser: String): String {
        val c = client ?: throw InCallException.NotRegistered
        val s = session ?: throw InCallException.NotRegistered
        // WebRTC set-up is heavy (native audio engine, ICE gathering): keep it off the app's main thread.
        val m = withContext(Dispatchers.Default) { WebRtcMedia(context, s, forceRelay) }.also { media = it }
        m.onQuality = { q -> onMain { events?.onQualityUpdated(q, currentCallId ?: "") } }
        val offer = withContext(Dispatchers.Default) { m.createOffer() }   // fix #2
        val id = "call-" + UUID.randomUUID().toString().substring(0, 8)
        currentCallId = id
        // Return straight away so the app can show the call; ringing, answer or refusal arrive as events.
        scope.launch {
            try {
                val answer = c.invite(sipUser, offer) { status ->
                    if (status in 180..183) onMain { events?.onCallStateChanged(CallState.Ringing, id) }
                }
                m.setAnswer(answer)
                onMain { events?.onCallStateChanged(CallState.Connected, id) }
            } catch (e: Exception) {
                // Answered, but our media couldn't start: hang up, or the other side stays in the call.
                if (e !is SipWsClient.InviteFailed) {
                    runCatching { c.bye() }
                    onMain { events?.onFailure(e as? InCallException ?: InCallException.MediaFailed(e.message ?: "media")) }
                }
                m.close(); if (media === m) media = null
                val reason = when ((e as? SipWsClient.InviteFailed)?.status) {
                    486, 600 -> CallEndReason.BUSY
                    603 -> CallEndReason.DECLINED
                    487 -> CallEndReason.ENDED                  // we cancelled it
                    408, 480 -> CallEndReason.NO_ANSWER
                    404 -> CallEndReason.UNREACHABLE
                    else -> CallEndReason.UNREACHABLE
                }
                onMain { events?.onCallStateChanged(CallState.Ended(reason), id) }
            }
        }
        return id
    }

    @Volatile private var answering = false

    override suspend fun answer() {
        if (answering) return   // answering takes a moment; ignore a second tap
        answering = true
        try { answerOnce() } finally { answering = false }
    }

    private suspend fun answerOnce() {
        val c = client ?: throw InCallException.NotRegistered
        val s = session ?: throw InCallException.NotRegistered
        val offer = pendingOffer ?: throw InCallException.MediaFailed("no pending call")
        val m = withContext(Dispatchers.Default) { WebRtcMedia(context, s, forceRelay) }.also { media = it }
        m.onQuality = { q -> onMain { events?.onQualityUpdated(q, currentCallId ?: "") } }
        val answerSdp = try {
            withContext(Dispatchers.Default) { m.acceptOffer(offer) }   // fix #1
        } catch (e: Exception) {   // can't start media: refuse the call rather than leave it ringing
            m.close(); media = null
            decline()
            throw e as? InCallException ?: InCallException.MediaFailed(e.message ?: "media")
        }
        c.answerIncoming(answerSdp)
        pendingOffer = null
        onMain { events?.onCallStateChanged(CallState.Connected, currentCallId ?: "") }
    }

    override suspend fun decline() {
        client?.declineIncoming(); pendingOffer = null
        val id = currentCallId ?: return
        onMain { events?.onCallStateChanged(CallState.Ended(CallEndReason.DECLINED), id) }
    }
    override suspend fun cancel() { client?.cancelInvite() }   // the INVITE ends with 487; dial()'s coroutine cleans up
    /** End whatever call there is: decline one that's ringing here, cancel one we're still placing, or BYE a live one. */
    override suspend fun hangup() {
        if (pendingOffer != null) { decline(); return }
        val c = client
        if (c != null && c.hasOutgoingInvite()) { c.cancelInvite(); return }   // dial()'s coroutine reports the end
        c?.bye(); media?.close(); media = null
        val id = currentCallId ?: return
        onMain { events?.onCallStateChanged(CallState.Ended(CallEndReason.ENDED), id) }
    }
    override suspend fun setMuted(muted: Boolean) { media?.setMuted(muted) }
    /** Hold: tell the other side (re-INVITE, a=sendonly) and stop sending our audio; resume reverses both. */
    override suspend fun setHold(held: Boolean) {
        val m = media ?: return
        val c = client ?: return
        m.setHold(held)
        val ok = runCatching {
            val offer = withContext(Dispatchers.Default) { m.reOffer(held) }   // the engine writes the hold SDP
            val answer = c.reInvite(offer) ?: throw InCallException.Network("refused")
            withContext(Dispatchers.Default) { m.setAnswer(answer) }
        }.isSuccess
        if (!ok) onMain { events?.onFailure(InCallException.Network(if (held) "couldn't put the call on hold" else "couldn't resume the call")) }
    }
    override suspend fun setAudioRoute(route: AudioRoute) {}          // via ConnectionService / AudioManager
    override suspend fun sendDtmf(tone: String) {}                    // TODO: DtmfSender
    override suspend fun transfer(sipUser: String) {                 // blind transfer via in-dialog REFER
        (client ?: throw InCallException.NotRegistered).refer(sipUser)
    }

    // --- Chat/location (same as SignallingSipTransport) ---

    override suspend fun sendMessage(sipUser: String, text: String?, location: SharedLocation?): String {
        val c = client ?: throw InCallException.NotRegistered
        val id = "me:" + UUID.randomUUID().toString().substring(0, 10)
        val payload = JSONObject().put("key", id)
        if (location != null) payload.put("t", "loc").put("loc", JSONObject().put("lat", location.lat).put("lng", location.lng).put("label", location.label))
        else payload.put("t", "text").put("text", text ?: "")
        c.message(sipUser, "application/json", payload.toString())
        return id
    }

    override suspend fun setTyping(typing: Boolean, sipUser: String) {
        try { client?.message(sipUser, "application/json", JSONObject().put("t", "typing").put("on", typing).toString()) } catch (_: Exception) {}
    }

    private fun handleInbound(fromSip: String, body: String) {
        val obj = try { JSONObject(body) } catch (_: Exception) { return }
        val key = obj.optString("key", UUID.randomUUID().toString())
        when (obj.optString("t")) {
            "text" -> onMain { events?.onMessage(fromSip, obj.optString("text"), null, key) }
            "loc" -> obj.optJSONObject("loc")?.let { l ->
                val loc = SharedLocation(l.optDouble("lat"), l.optDouble("lng"), l.optString("label", "Shared location"))
                onMain { events?.onMessage(fromSip, null, loc, key) }
            }
            "conf" -> {   // an invitation into a 3-way call (same JSON the web client sends)
                val room = obj.optString("room")
                if (Regex("^cf-[0-9a-f]{12}$").matches(room)) {
                    val with = obj.optJSONArray("with")?.let { a -> (0 until a.length()).map { a.optString(it) } } ?: emptyList()
                    onMain { events?.onConferenceInvite(fromSip, room, obj.optBoolean("move"), with) }
                }
            }
        }
    }
}
