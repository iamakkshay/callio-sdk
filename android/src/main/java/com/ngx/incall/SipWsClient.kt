package com.ngx.incall

import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * SIP-over-WebSocket signalling client (RFC 7118) — the **signalling half** of the native transport.
 * Opens the `wss`, REGISTERs with digest auth, sends/receives SIP MESSAGE (chat/location), and carries
 * INVITE/ACK/BYE. **No media**: the WebRTC PeerConnection and the five SDP/ICE fixes (see
 * SipTransport.kt / WEBRTC_TRANSPORT_PORT.md) are supplied by the caller — `invite(sdpOffer)` takes an
 * offer and returns the answer SDP. Registration and chat work as-is.
 */
internal class SipWsClient(private val cfg: Config) {
    data class Config(val wss: String, val realm: String, val sipUser: String, val authUser: String, val password: String)

    private val http = OkHttpClient()
    private var ws: WebSocket? = null
    private val lock = Any()
    private var cseq = 0
    private val pending = HashMap<Int, CancellableContinuation<SipMessage>>()
    private val callId = randToken() + "@incall.invalid"
    private val fromTag = randToken()
    private val contactHost = randToken() + ".invalid"
    @Volatile private var incomingInvite: SipMessage? = null   // the last inbound INVITE, to answer/decline

    /** Established INVITE dialog (from the 2xx as caller, or the inbound INVITE as callee) so we can ACK
     * the 2xx and send in-dialog BYE/REFER. The lab Kamailio doesn't Record-Route, so `routes` is usually
     * empty; carried through for a proxy that does. */
    private data class Dialog(
        val localAor: String, val remoteAor: String, val remoteTarget: String, val remoteTag: String, val routes: List<String>,
    )
    @Volatile private var dialog: Dialog? = null

    var onChatMessage: ((fromSip: String, body: String) -> Unit)? = null
    var onIncomingInvite: ((fromSip: String, sdpOffer: String, callId: String) -> Unit)? = null
    var onBye: ((callId: String) -> Unit)? = null

    fun connect() {
        val req = Request.Builder().url(cfg.wss).header("Sec-WebSocket-Protocol", "sip").build()
        ws = http.newWebSocket(req, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) { handle(SipMessage.parse(text)) }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { failAllPending() }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { failAllPending() }
        })
    }

    fun close() { ws?.close(1000, null); ws = null }

    // REGISTER (with digest), FR-SDK-04 / fix #4
    suspend fun register(expires: Int = 120) {
        val aor = "sip:${cfg.sipUser}@${cfg.realm}"
        suspend fun send(auth: String?): SipMessage {
            val n = nextCseq()
            val headers = baseHeaders("REGISTER", aor, aor, n).toMutableList()
            headers.add("Contact" to "<sip:${cfg.sipUser}@$contactHost;transport=ws>")
            headers.add("Expires" to expires.toString())
            if (auth != null) headers.add("Authorization" to auth)
            return request(n, "REGISTER", "sip:${cfg.realm}", headers)
        }
        var resp = send(null)
        if (resp.statusCode == 401) {
            val ch = resp.header("WWW-Authenticate")?.let { DigestAuth.parseChallenge(it) }
            if (ch != null) resp = send(DigestAuth.authorization(cfg.authUser, cfg.password, "REGISTER", "sip:${cfg.realm}", ch))
        }
        if (resp.statusCode != 200) throw InCallException.Network("REGISTER failed (${resp.statusCode})")
    }

    suspend fun unregister() { try { register(0) } catch (_: Exception) {} }

    // MESSAGE (chat), FR-CHAT-01
    suspend fun message(toSip: String, contentType: String, body: String): String {
        val n = nextCseq()
        val target = "sip:$toSip@${cfg.realm}"
        val headers = baseHeaders("MESSAGE", target, "sip:${cfg.sipUser}@${cfg.realm}", n).toMutableList()
        headers.add("Content-Type" to contentType)
        val resp = request(n, "MESSAGE", target, headers, body)
        if (resp.statusCode != 200) throw InCallException.Network("MESSAGE failed (${resp.statusCode})")
        return callId
    }

    // INVITE (signalling; media SDP supplied by the caller). fix #2: candidates already in the offer.
    suspend fun invite(toSip: String, sdpOffer: String): String {
        val target = "sip:$toSip@${cfg.realm}"
        suspend fun send(auth: String?): SipMessage {
            val n = nextCseq()
            val headers = baseHeaders("INVITE", target, "sip:${cfg.sipUser}@${cfg.realm}", n).toMutableList()
            headers.add("Contact" to "<sip:${cfg.sipUser}@$contactHost;transport=ws>")
            headers.add("Content-Type" to "application/sdp")
            if (auth != null) headers.add("Proxy-Authorization" to auth)
            return request(n, "INVITE", target, headers, sdpOffer)
        }
        var resp = send(null)
        if (resp.statusCode == 407) {
            val ch = resp.header("Proxy-Authenticate")?.let { DigestAuth.parseChallenge(it) }
            if (ch != null) resp = send(DigestAuth.authorization(cfg.authUser, cfg.password, "INVITE", target, ch))
        }
        if (resp.statusCode != 200) throw InCallException.Network("INVITE failed (${resp.statusCode})")
        // Establish the dialog and ACK the 2xx (a separate transaction to the remote target — RFC 3261
        // §13.2.2.4). Without the ACK the callee retransmits the 200 and tears the call down.
        val d = Dialog(
            localAor = "sip:${cfg.sipUser}@${cfg.realm}",
            remoteAor = target,
            remoteTarget = uriOf(resp.header("Contact")) ?: target,
            remoteTag = tagOf(resp.header("To")),
            routes = resp.headers.filter { it.first.equals("Record-Route", true) }.map { it.second },
        )
        dialog = d
        sendInDialog("ACK", d, cseqNumber(resp) ?: nextCseq())
        return resp.body   // the answer SDP, for setRemoteDescription
    }

    /** Send an in-dialog request (ACK/BYE/REFER) to the remote target. ACK reuses the INVITE's CSeq; the
     * others take a fresh one. ACK is fire-and-forget; BYE/REFER await their final response. */
    private fun sendInDialog(method: String, d: Dialog, cseqNum: Int, extra: List<Pair<String, String>> = emptyList()) {
        val w = ws ?: return
        val headers = mutableListOf(
            "Via" to "SIP/2.0/WS $contactHost;branch=z9hG4bK${randToken()}",
            "Max-Forwards" to "70",
        )
        d.routes.forEach { headers.add("Route" to it) }
        headers.add("To" to "<${d.remoteAor}>;tag=${d.remoteTag}")
        headers.add("From" to "<${d.localAor}>;tag=$fromTag")
        headers.add("Call-ID" to callId)
        headers.add("CSeq" to "$cseqNum $method")
        headers.addAll(extra)
        w.send(SipMessage.buildRequest(method, d.remoteTarget, headers, ""))
    }

    /** Hang up an established call: in-dialog BYE, wait (briefly) for its 200. */
    suspend fun bye() {
        val d = dialog ?: return
        val n = nextCseq()
        withTimeoutOrNull(4000) {
            suspendCancellableCoroutine<SipMessage> { cont ->
                synchronized(lock) { pending[n] = cont }
                sendInDialog("BYE", d, n)
            }
        }
        synchronized(lock) { pending.remove(n) }
        dialog = null
    }

    /** Blind transfer (REFER) the established call to another user. In-dialog; proxy routes by alias. */
    suspend fun refer(toSip: String) {
        val d = dialog ?: throw InCallException.Network("no active call to transfer")
        val n = nextCseq()
        val resp = withTimeoutOrNull(4000) {
            suspendCancellableCoroutine<SipMessage> { cont ->
                synchronized(lock) { pending[n] = cont }
                sendInDialog("REFER", d, n, listOf(
                    "Refer-To" to "<sip:$toSip@${cfg.realm}>",
                    "Referred-By" to "<${d.localAor}>",
                ))
            }
        }
        synchronized(lock) { pending.remove(n) }
        if (resp == null || (resp.statusCode ?: 0) / 100 != 2) throw InCallException.Network("REFER failed (${resp?.statusCode})")
    }

    /** Answer the pending inbound INVITE with 200 OK + the WebRTC answer SDP (echoes dialog headers). */
    fun answerIncoming(sdp: String) {
        val inv = incomingInvite ?: return
        val w = ws ?: return
        var to = inv.header("To") ?: ""
        if (!to.contains(";tag=")) to += ";tag=$fromTag"
        val headers = listOf(
            "Via" to (inv.header("Via") ?: ""),
            "From" to (inv.header("From") ?: ""),
            "To" to to,
            "Call-ID" to (inv.header("Call-ID") ?: callId),
            "CSeq" to (inv.header("CSeq") ?: "1 INVITE"),
            "Contact" to "<sip:${cfg.sipUser}@$contactHost;transport=ws>",
            "Content-Type" to "application/sdp",
        )
        w.send(SipMessage.buildResponse(200, "OK", headers, sdp))
        // Record the dialog from the inbound INVITE so this (answering) side can send BYE/REFER too.
        dialog = Dialog(
            localAor = "sip:${cfg.sipUser}@${cfg.realm}",
            remoteAor = uriOf(inv.header("From")) ?: "sip:unknown@${cfg.realm}",
            remoteTarget = uriOf(inv.header("Contact")) ?: (uriOf(inv.header("From")) ?: ""),
            remoteTag = tagOf(inv.header("From")),
            routes = inv.headers.filter { it.first.equals("Record-Route", true) }.map { it.second },
        )
    }

    /** Reject the pending inbound INVITE (decline = 603, busy = 486). */
    fun declineIncoming(status: Int = 603, reason: String = "Decline") {
        val inv = incomingInvite ?: return
        val w = ws ?: return
        val headers = listOf(
            "Via" to (inv.header("Via") ?: ""),
            "From" to (inv.header("From") ?: ""),
            "To" to ((inv.header("To") ?: "") + ";tag=$fromTag"),
            "Call-ID" to (inv.header("Call-ID") ?: callId),
            "CSeq" to (inv.header("CSeq") ?: "1 INVITE"),
        )
        w.send(SipMessage.buildResponse(status, reason, headers))
        incomingInvite = null
    }

    private fun handle(m: SipMessage) {
        val code = m.statusCode
        if (code != null) {                              // a response to one of our requests
            if (code >= 200) cseqNumber(m)?.let { takePending(it)?.resume(m) }   // ignore provisional 1xx
            return
        }
        when (m.method) {                                // an inbound request from the peer
            "MESSAGE" -> onChatMessage?.invoke(aorUser(m.header("From")), m.body)
            "INVITE" -> { incomingInvite = m; onIncomingInvite?.invoke(aorUser(m.header("From")), m.body, m.header("Call-ID") ?: callId) }
            "BYE" -> { dialog = null; onBye?.invoke(m.header("Call-ID") ?: callId) }
        }
    }

    private fun nextCseq(): Int = synchronized(lock) { ++cseq }
    private fun takePending(n: Int): CancellableContinuation<SipMessage>? = synchronized(lock) { pending.remove(n) }
    private fun failAllPending() {
        val all = synchronized(lock) { val copy = HashMap(pending); pending.clear(); copy }
        all.values.forEach { it.resumeWithException(InCallException.Network("socket closed")) }
    }

    private suspend fun request(
        cseqNum: Int, method: String, requestURI: String, headers: List<Pair<String, String>>, body: String = "",
    ): SipMessage {
        val w = ws ?: throw InCallException.NotRegistered
        val raw = SipMessage.buildRequest(method, requestURI, headers, body)
        return suspendCancellableCoroutine { cont ->
            synchronized(lock) { pending[cseqNum] = cont }
            if (!w.send(raw)) takePending(cseqNum)?.resumeWithException(InCallException.Network("send failed"))
        }
    }

    private fun baseHeaders(method: String, to: String, from: String, cseqNum: Int): List<Pair<String, String>> = listOf(
        "Via" to "SIP/2.0/WS $contactHost;branch=z9hG4bK${randToken()}",
        "Max-Forwards" to "70",
        "From" to "<$from>;tag=$fromTag",
        "To" to "<$to>",
        "Call-ID" to callId,
        "CSeq" to "$cseqNum $method",
        "User-Agent" to "InCallSDK-android/${InCallSdkVersion.CURRENT}",
    )

    private fun cseqNumber(m: SipMessage): Int? = m.header("CSeq")?.split(" ")?.firstOrNull()?.toIntOrNull()

    private fun aorUser(header: String?): String {
        val h = header ?: return ""
        val i = h.indexOf("sip:"); if (i < 0) return ""
        return h.substring(i + 4).takeWhile { it != '@' && it != '>' }
    }

    private fun tagOf(header: String?): String {
        val h = header ?: return ""
        val i = h.indexOf("tag="); if (i < 0) return ""
        return h.substring(i + 4).takeWhile { it != ';' && it != '>' && it != ' ' && it != '\r' && it != '\n' }
    }

    private fun uriOf(header: String?): String? {
        val h = header ?: return null
        val lt = h.indexOf('<'); val gt = if (lt >= 0) h.indexOf('>', lt + 1) else -1
        if (lt >= 0 && gt > lt) return h.substring(lt + 1, gt)
        val v = h.trim(); return if (v.isEmpty()) null else v
    }

    private fun randToken() = UUID.randomUUID().toString().replace("-", "").substring(0, 12)
}
