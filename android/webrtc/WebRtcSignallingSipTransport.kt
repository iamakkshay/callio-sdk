// WebRtcSignallingSipTransport — SignallingSipTransport + real WebRTC calls. Compiled under `-PwithWebRtc`
// (see WebRtcMedia.kt's header + build.gradle.kts). A calling host app points InCallClient at
// `WebRtcSignallingSipTransport(context)` instead of the signalling-only SignallingSipTransport().
package com.ngx.incall

import android.content.Context
import android.os.Handler
import android.os.Looper
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
        c.onBye = { callId -> media?.close(); media = null; onMain { events?.onCallStateChanged(CallState.Ended(CallEndReason.ENDED), callId) } }
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
        val m = WebRtcMedia(context, s, forceRelay).also { media = it }
        m.onQuality = { q -> onMain { events?.onQualityUpdated(q, currentCallId ?: "") } }
        val offer = m.createOffer()                        // fix #2
        val answer = c.invite(sipUser, offer)
        m.setAnswer(answer)
        val id = "call-" + UUID.randomUUID().toString().substring(0, 8)
        currentCallId = id
        onMain { events?.onCallStateChanged(CallState.Connected, id) }
        return id
    }

    override suspend fun answer() {
        val c = client ?: throw InCallException.NotRegistered
        val s = session ?: throw InCallException.NotRegistered
        val offer = pendingOffer ?: throw InCallException.MediaFailed("no pending call")
        val m = WebRtcMedia(context, s, forceRelay).also { media = it }
        m.onQuality = { q -> onMain { events?.onQualityUpdated(q, currentCallId ?: "") } }
        val answerSdp = m.acceptOffer(offer)               // fix #1
        c.answerIncoming(answerSdp)
        pendingOffer = null
        onMain { events?.onCallStateChanged(CallState.Connected, currentCallId ?: "") }
    }

    override suspend fun decline() { client?.declineIncoming(); pendingOffer = null }
    override suspend fun cancel() { client?.bye(); media?.close(); media = null }
    override suspend fun hangup() { client?.bye(); media?.close(); media = null }   // in-dialog BYE + release media
    override suspend fun setMuted(muted: Boolean) { media?.setMuted(muted) }
    override suspend fun setHold(held: Boolean) { media?.setHold(held) }
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
        }
    }
}
