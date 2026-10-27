package com.ngx.incall

import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.util.UUID

/**
 * The default transport. **Registration and chat are fully implemented** over [SipWsClient]
 * (SIP-over-WSS + digest auth); the **call methods require WebRTC** and throw until the media layer
 * (PeerConnection + the five SDP/ICE fixes — see SipTransport.kt / WEBRTC_TRANSPORT_PORT.md) is added.
 * A native app built on this can register and exchange chat/location against the lab Kamailio today.
 */
internal class SignallingSipTransport : SipTransport {
    override var events: SipTransportEvents? = null

    private var client: SipWsClient? = null
    private val main = Handler(Looper.getMainLooper())
    private fun onMain(block: () -> Unit) { main.post(block) }
    private fun needsMedia() =
        InCallException.MediaFailed("WebRTC media not implemented — wire PeerConnection into SipWsClient.invite/answer")

    override suspend fun register(session: Session, forceRelay: Boolean) {
        onMain { events?.onRegistrationChanged(RegistrationState.CONNECTING) }
        val c = SipWsClient(SipWsClient.Config(session.wss, session.realm, session.sipUser, session.authUser, session.sipPassword))
        c.onChatMessage = { fromSip, body -> handleInbound(fromSip, body) }
        c.onIncomingInvite = { fromSip, _, callId -> onMain { events?.onIncomingCall(fromSip, callId) } }
        c.onBye = { callId -> onMain { events?.onCallStateChanged(CallState.Ended(CallEndReason.ENDED), callId) } }
        client = c
        c.connect()
        c.register()
        onMain { events?.onRegistrationChanged(RegistrationState.REGISTERED) }
    }

    override suspend fun unregister() { client?.unregister(); client?.close(); client = null }

    override suspend fun sendMessage(sipUser: String, text: String?, location: SharedLocation?): String {
        val c = client ?: throw InCallException.NotRegistered
        val id = "me:" + UUID.randomUUID().toString().substring(0, 10)
        val payload = JSONObject().put("key", id)
        if (location != null) {
            payload.put("t", "loc").put("loc", JSONObject().put("lat", location.lat).put("lng", location.lng).put("label", location.label))
        } else {
            payload.put("t", "text").put("text", text ?: "")
        }
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

    // Call control — requires the WebRTC media layer (throws until wired).
    override suspend fun dial(sipUser: String): String = throw needsMedia()
    override suspend fun answer() = throw needsMedia()
    override suspend fun decline() {}
    override suspend fun cancel() {}
    override suspend fun hangup() {}
    override suspend fun setMuted(muted: Boolean) {}
    override suspend fun setHold(held: Boolean) {}
    override suspend fun setAudioRoute(route: AudioRoute) {}
    override suspend fun sendDtmf(tone: String) {}
    override suspend fun transfer(sipUser: String) = throw needsMedia()
}
