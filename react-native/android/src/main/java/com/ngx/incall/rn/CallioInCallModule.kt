// Android native module for @clarigoinfotech/callio-react-native (FR-SDK-02): React Native bridge <-> com.ngx.incall. Same calls
// as the Flutter plugin; events go out on one "CallioInCallEvent" channel as { event, ...payload }.
package com.ngx.incall.rn

import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.ngx.incall.*
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class CallioInCallModule(private val ctx: ReactApplicationContext) : ReactContextBaseJavaModule(ctx), InCallListener {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val pendingTokens = ConcurrentHashMap<String, CompletableDeferred<String?>>()
    private var client: InCallClient? = null

    override fun getName() = "CallioInCall"

    // NativeEventEmitter on the JS side calls these; nothing to do, events are sent regardless.
    @ReactMethod fun addListener(eventName: String) {}
    @ReactMethod fun removeListeners(count: Double) {}

    private fun emit(map: WritableMap) {
        if (ctx.hasActiveReactInstance()) ctx.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java).emit("CallioInCallEvent", map)
    }

    private fun run(promise: Promise, name: String, body: suspend () -> Any?) {
        scope.launch {
            try { promise.resolve(body()) } catch (e: Exception) { promise.reject(name, e.message, e) }
        }
    }

    // ---- token round trip: native asks JS, JS answers with provideToken ----
    private suspend fun tokenFromJS(): String {
        val id = UUID.randomUUID().toString()
        val d = CompletableDeferred<String?>()
        pendingTokens[id] = d
        emit(Arguments.createMap().apply { putString("event", "tokenRequest"); putString("requestId", id) })
        val token = withTimeoutOrNull(20_000) { d.await() }
        pendingTokens.remove(id)
        return token ?: throw InCallException.TokenExpired
    }

    @ReactMethod fun provideToken(requestId: String, token: String?) {
        pendingTokens.remove(requestId)?.complete(token?.takeIf { it.isNotEmpty() })
    }

    @ReactMethod fun start(baseUrl: String, forceRelay: Boolean, promise: Promise) = run(promise, "start") {
        val c = InCallClient(ctx.applicationContext, InCallConfig(baseUrl, forceRelay) { tokenFromJS() })
        c.addListener(this)
        client = c
        c.start()
        null
    }
    @ReactMethod fun stop(promise: Promise) = run(promise, "stop") { client?.stop(); null }
    @ReactMethod fun dial(sipUser: String, promise: Promise) = run(promise, "dial") { requireClient().dial(contact(sipUser)).id }
    @ReactMethod fun answer(promise: Promise) = run(promise, "answer") { client?.currentCall?.answer(); null }
    @ReactMethod fun decline(promise: Promise) = run(promise, "decline") { client?.currentCall?.decline(); null }
    @ReactMethod fun hangup(promise: Promise) = run(promise, "hangup") { client?.currentCall?.hangup(); null }
    @ReactMethod fun setMuted(muted: Boolean, promise: Promise) = run(promise, "setMuted") { client?.currentCall?.setMuted(muted); null }
    @ReactMethod fun setHold(held: Boolean, promise: Promise) = run(promise, "setHold") { client?.currentCall?.setHold(held); null }
    @ReactMethod fun sendDtmf(tone: String, promise: Promise) = run(promise, "sendDtmf") { client?.currentCall?.sendDtmf(tone); null }
    @ReactMethod fun setAudioRoute(route: String, promise: Promise) = run(promise, "setAudioRoute") {
        client?.currentCall?.setAudioRoute(AudioRoute.valueOf(route.uppercase())); null
    }
    @ReactMethod fun sendText(to: String, text: String, promise: Promise) = run(promise, "sendText") { requireClient().thread(contact(to)).send(text).id }
    @ReactMethod fun sendLocation(to: String, lat: Double, lng: Double, label: String, promise: Promise) = run(promise, "sendLocation") {
        requireClient().thread(contact(to)).sendLocation(SharedLocation(lat, lng, label)).id
    }
    @ReactMethod fun setTyping(to: String, typing: Boolean, promise: Promise) = run(promise, "setTyping") { client?.thread(contact(to))?.setTyping(typing); null }
    @ReactMethod fun callHistory(limit: Double, promise: Promise) = run(promise, "callHistory") {
        Arguments.createArray().apply {
            for (h in requireClient().callHistory(limit.toInt())) pushMap(Arguments.createMap().apply {
                putString("callId", h.callId); putString("peer", h.peer); putString("peerDisplayName", h.peerDisplayName)
                putString("direction", h.direction.name.lowercase()); putString("outcome", h.outcome)
                putInt("durationSec", h.durationSec); putString("at", h.at)
            })
        }
    }
    @ReactMethod fun registerPush(token: String, promise: Promise) = run(promise, "registerPush") { client?.push?.register(token); null }

    private fun requireClient() = client ?: throw InCallException.NotRegistered
    private fun contact(sip: String): Contact =
        client?.directory?.firstOrNull { it.sipUser == sip || it.name == sip } ?: Contact(sip, sip, sip, UserType.CUSTOMER)

    // ---- InCallListener -> JS ----
    private fun event(name: String, fill: WritableMap.() -> Unit) = emit(Arguments.createMap().apply { putString("event", name); fill() })

    override fun onRegistrationChanged(state: RegistrationState) = event("registration") { putString("state", state.name.lowercase()) }
    override fun onIncomingCall(call: Call) = event("incomingCall") {
        putString("callId", call.id)
        putMap("from", Arguments.createMap().apply {
            putString("name", call.peer.name); putString("sipUser", call.peer.sipUser)
            putString("displayName", call.peer.displayName); putString("userType", call.peer.userType.wire)
        })
    }
    override fun onCallStateChanged(call: Call) = event("callState") { putString("callId", call.id); putString("state", stateName(call.state)) }
    override fun onCallQualityUpdated(quality: CallQuality) = event("quality") {
        putMap("quality", Arguments.createMap().apply {
            quality.rttMs?.let { putDouble("rttMs", it.toDouble()) }; quality.jitterMs?.let { putDouble("jitterMs", it.toDouble()) }
            quality.lossPct?.let { putDouble("lossPct", it.toDouble()) }; quality.mos?.let { putDouble("mos", it.toDouble()) }
        })
    }
    override fun onMessage(message: Message, thread: ChatThread) = event("message") {
        putString("peerSip", thread.peer.sipUser)
        putMap("message", Arguments.createMap().apply {
            putString("id", message.id); putString("from", message.from.name.lowercase()); putString("text", message.text)
            putString("status", message.status.name.lowercase())
            message.location?.let { l -> putMap("location", Arguments.createMap().apply { putDouble("lat", l.lat); putDouble("lng", l.lng); putString("label", l.label) }) }
        })
    }
    override fun onAudioRouteChanged(route: AudioRoute) = event("audioRoute") { putString("route", route.name.lowercase()) }
    override fun onFailure(error: InCallException) = event("failure") { putString("code", error.javaClass.simpleName); putString("message", error.message ?: "") }

    private fun stateName(s: CallState): String = when (s) {
        is CallState.Initiating -> "initiating"; is CallState.Ringing -> "ringing"; is CallState.Connected -> "connected"
        is CallState.OnHold -> "onHold"; is CallState.Reconnecting -> "reconnecting"; is CallState.Ended -> "ended"
    }

    override fun invalidate() { client?.removeListener(this); super.invalidate() }
}
