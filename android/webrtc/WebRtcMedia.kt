// WebRtcMedia — the on-device WebRTC media engine for Android. Compiled under `-PwithWebRtc` (which adds
// this webrtc/ dir to the main source set and pulls in libwebrtc — see build.gradle.kts + CI); omitted
// from the default build so a register+chat-only host app doesn't carry libwebrtc. To make it the SDK's
// default transport in a calling host app, point InCallClient at WebRtcSignallingSipTransport(context).
//
// Implements the five recovered media fixes (public/engine/ice.js, sip.js):
//   #1 answerer SDP candidate strip/re-add   #2 relay-wait ICE release (no trickle)   #3 TURN expansion
package com.ngx.incall

import android.content.Context
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.webrtc.*
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class WebRtcMedia(context: Context, session: Session, private val forceRelay: Boolean) {
    private val factory: PeerConnectionFactory
    private val pc: PeerConnection
    private val audioTrack: AudioTrack
    private val hasTurn = session.turn != null
    private val hasStun = session.stun != null

    private val lock = Any()
    private var gatherCont: CancellableContinuation<Unit>? = null
    private var gatherDone = false
    private val heldRemote = mutableListOf<Pair<String, String>>()   // fix #1: (candidate line, mid)
    private val scope = CoroutineScope(Dispatchers.Default)
    private var prev: Pair<Long, Long>? = null
    var onQuality: ((CallQuality) -> Unit)? = null

    init {
        if (initialized.compareAndSet(false, true)) {   // once per process; it loads the native library
            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions.builder(context.applicationContext).createInitializationOptions()
            )
        }
        factory = PeerConnectionFactory.builder().createPeerConnectionFactory()

        val iceServers = buildList {
            session.stun?.let { add(PeerConnection.IceServer.builder(it).createIceServer()) }
            if (session.turn != null && session.turnUser != null && session.turnPassword != null) {
                add(PeerConnection.IceServer.builder(turnUrls(session.turn))   // fix #3
                    .setUsername(session.turnUser).setPassword(session.turnPassword).createIceServer())
            }
        }
        val cfg = PeerConnection.RTCConfiguration(iceServers).apply {
            iceTransportsType = if (forceRelay) PeerConnection.IceTransportsType.RELAY else PeerConnection.IceTransportsType.ALL
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
        }
        pc = factory.createPeerConnection(cfg, Observer())!!
        val source = factory.createAudioSource(MediaConstraints())
        audioTrack = factory.createAudioTrack("audio0", source)
        pc.addTrack(audioTrack, listOf("stream0"))
    }

    // Outgoing: a candidate-laden offer (fix #2)
    suspend fun createOffer(): String {
        val offer = createSdp(outgoing = true)
        setLocal(offer)
        gatherIce()
        startStats()
        return pc.localDescription?.description ?: offer.description
    }

    suspend fun setAnswer(sdp: String) =
        setRemote(SessionDescription(SessionDescription.Type.ANSWER, sdp))

    // Incoming: strip the offer's candidates, answer, re-add (fix #1)
    suspend fun acceptOffer(remoteSdp: String): String {
        val (stripped, held, mid) = stripOfferCandidates(remoteSdp)
        synchronized(lock) { heldRemote.clear(); heldRemote.addAll(held.map { it to mid }) }
        setRemote(SessionDescription(SessionDescription.Type.OFFER, stripped))
        val answer = createSdp(outgoing = false)
        setLocal(answer)
        gatherIce()
        synchronized(lock) { heldRemote }.forEach { (line, m) ->
            pc.addIceCandidate(IceCandidate(m, 0, line.removePrefix("a=")))   // fix #1
        }
        startStats()
        return pc.localDescription?.description ?: answer.description
    }

    fun setMuted(muted: Boolean) { audioTrack.setEnabled(!muted) }
    fun setHold(held: Boolean) { audioTrack.setEnabled(!held) }   // minimal hold; true hold re-INVITEs (TODO)
    fun close() { scope.coroutineContext[kotlinx.coroutines.Job]?.cancel(); pc.close(); pc.dispose(); factory.dispose() }

    // fix #2: gather to a relay candidate (or complete, or a 2.5 s cap: an unreachable TURN server mustn't hold the call up)
    private suspend fun gatherIce() {
        if (pc.iceGatheringState() == PeerConnection.IceGatheringState.COMPLETE || gatherDone) return
        withTimeoutOrNull(2500L) {
            suspendCancellableCoroutine<Unit> { cont ->
                synchronized(lock) { if (gatherDone) cont.resume(Unit) else gatherCont = cont }
            }
        }
        gatherDone = true
    }
    private fun finishGather() {
        val c = synchronized(lock) { gatherDone = true; val x = gatherCont; gatherCont = null; x }
        c?.resume(Unit)
    }
    private fun candidateIsEnough(sdp: String): Boolean = when {
        sdp.contains("typ relay") -> true
        forceRelay || hasTurn -> false
        sdp.contains("typ srflx") -> true
        sdp.contains("typ host") && !hasStun -> true
        else -> false
    }

    private val recvAudio get() = MediaConstraints().apply {
        mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
    }

    // SdpObserver -> coroutine wrappers
    private suspend fun createSdp(outgoing: Boolean): SessionDescription = suspendCancellableCoroutine { cont ->
        val obs = object : SdpObserver {
            override fun onCreateSuccess(sdp: SessionDescription) { cont.resume(sdp) }
            override fun onCreateFailure(e: String?) { cont.resumeWithException(InCallException.MediaFailed(e ?: "create")) }
            override fun onSetSuccess() {}
            override fun onSetFailure(e: String?) {}
        }
        if (outgoing) pc.createOffer(obs, recvAudio) else pc.createAnswer(obs, recvAudio)
    }
    private suspend fun setLocal(sdp: SessionDescription) = setSdp(sdp, local = true)
    private suspend fun setRemote(sdp: SessionDescription) = setSdp(sdp, local = false)
    private suspend fun setSdp(sdp: SessionDescription, local: Boolean): Unit = suspendCancellableCoroutine { cont ->
        val obs = object : SdpObserver {
            override fun onSetSuccess() { cont.resume(Unit) }
            override fun onSetFailure(e: String?) { cont.resumeWithException(InCallException.MediaFailed(e ?: "set")) }
            override fun onCreateSuccess(sdp: SessionDescription) {}
            override fun onCreateFailure(e: String?) {}
        }
        if (local) pc.setLocalDescription(obs, sdp) else pc.setRemoteDescription(obs, sdp)
    }

    // stats -> CallQuality (FR-CALL-11)
    private fun startStats() = scope.launch {
        while (isActive) {
            pc.getStats { report -> parseStats(report) }
            delay(1000)
        }
    }
    private fun parseStats(report: RTCStatsReport) {
        var rtt: Int? = null; var jitter: Int? = null; var loss: Double? = null
        var received = 0L; var lost = 0L
        for (s in report.statsMap.values) {
            if (s.type == "candidate-pair" && s.members["nominated"] == true) {
                (s.members["currentRoundTripTime"] as? Double)?.let { rtt = (it * 1000).toInt() }
            }
            if (s.type == "inbound-rtp" && s.members["kind"] == "audio") {
                received = (s.members["packetsReceived"] as? Number)?.toLong() ?: 0
                lost = (s.members["packetsLost"] as? Number)?.toLong() ?: 0
                (s.members["jitter"] as? Double)?.let { jitter = (it * 1000).toInt() }
            }
        }
        prev?.let { (pr, pl) ->
            if (received > pr) { val dr = (received - pr).toDouble(); val dl = (lost - pl).toDouble(); loss = if (dr + dl > 0) dl / (dr + dl) * 100 else 0.0 }
        }
        prev = received to lost
        onQuality?.invoke(CallQuality(rtt, jitter, loss, null))
    }

    private inner class Observer : PeerConnection.Observer {
        override fun onIceCandidate(candidate: IceCandidate) { if (candidateIsEnough(candidate.sdp)) finishGather() }  // fix #2
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) { if (state == PeerConnection.IceGatheringState.COMPLETE) finishGather() }
        override fun onSignalingChange(state: PeerConnection.SignalingState?) {}
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {}
        override fun onIceConnectionReceivingChange(receiving: Boolean) {}
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
        override fun onAddStream(stream: MediaStream?) {}
        override fun onRemoveStream(stream: MediaStream?) {}
        override fun onDataChannel(dc: DataChannel?) {}
        override fun onRenegotiationNeeded() {}
        override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) {}
    }

    companion object {
        private val initialized = java.util.concurrent.atomic.AtomicBoolean(false)

        /** Expand a bare TURN URL to UDP/TCP/TLS (fix #3). */
        fun turnUrls(url: String): List<String> {
            val host = url.substringAfter(":").substringBefore("?").substringBefore(":")
            return listOf("turn:$host:3478?transport=udp", "turn:$host:3478?transport=tcp", "turns:$host:5349?transport=tcp")
        }

        /** Strip a=candidate / a=end-of-candidates from an inbound offer (fix #1). Returns (sdp, held, mid). */
        fun stripOfferCandidates(sdp: String): Triple<String, List<String>, String> {
            val lines = sdp.replace("\r\n", "\n").split("\n")
            val mid = lines.firstOrNull { it.startsWith("a=mid:") }?.removePrefix("a=mid:") ?: "0"
            val held = lines.filter { it.startsWith("a=candidate") }
            if (held.isEmpty()) return Triple(sdp, emptyList(), mid)
            val kept = lines.filter { !it.startsWith("a=candidate") && it != "a=end-of-candidates" }.joinToString("\r\n")
            return Triple(kept, held, mid)
        }
    }
}
