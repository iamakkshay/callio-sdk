// Android bridge for the incall_flutter plugin: MethodChannel + EventChannel <-> the native
// com.ngx.incall SDK. REFERENCE — compiles once the incall-sdk library is a dependency of this plugin
// (add `implementation project(':incall-sdk')` or the published artifact in android/build.gradle).
package com.ngx.incall.flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.ngx.incall.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

class InCallFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, InCallListener {
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(Dispatchers.Main)
    private var sink: EventChannel.EventSink? = null
    private var client: InCallClient? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "incall_flutter").also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(binding.binaryMessenger, "incall_flutter/events").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null); eventChannel.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> scope.launch {
                try {
                    val baseUrl = call.argument<String>("baseUrl")!!
                    val forceRelay = call.argument<Boolean>("forceRelay") ?: false
                    val config = InCallConfig(baseUrl, forceRelay) { tokenFromDart() }
                    val c = InCallClient(context, config).also { it.addListener(this@InCallFlutterPlugin) }
                    client = c
                    c.start()
                    result.success(null)
                } catch (e: Exception) { result.error("start", e.message, null) }
            }
            "stop" -> scope.launch { client?.stop(); result.success(null) }
            "dial" -> scope.launch {
                try {
                    val target = directoryContact(call.argument<String>("sipUser")!!)
                    val cCall = client!!.dial(target)
                    result.success(cCall.id)
                } catch (e: Exception) { result.error("dial", e.message, null) }
            }
            "answer" -> scope.launch { runCatching { client?.currentCall?.answer() }; result.success(null) }
            "decline" -> scope.launch { client?.currentCall?.decline(); result.success(null) }
            "hangup" -> scope.launch { client?.currentCall?.hangup(); result.success(null) }
            "setMuted" -> scope.launch { client?.currentCall?.setMuted(call.argument<Boolean>("muted") ?: false); result.success(null) }
            "setHold" -> scope.launch { client?.currentCall?.setHold(call.argument<Boolean>("held") ?: false); result.success(null) }
            "setAudioRoute" -> scope.launch {
                runCatching { client?.currentCall?.setAudioRoute(AudioRoute.valueOf((call.argument<String>("route") ?: "").uppercase())) }
                result.success(null)
            }
            "sendDtmf" -> scope.launch { client?.currentCall?.sendDtmf(call.argument<String>("tone") ?: ""); result.success(null) }
            "sendMessage" -> scope.launch {
                try {
                    val to = directoryContact(call.argument<String>("to")!!)
                    val loc = call.argument<Map<String, Any>>("location")?.let {
                        SharedLocation((it["lat"] as Number).toDouble(), (it["lng"] as Number).toDouble(), it["label"] as? String ?: "Shared location")
                    }
                    val id = client!!.thread(to).let {
                        if (loc != null) it.sendLocation(loc).id else it.send(call.argument<String>("text") ?: "").id
                    }
                    result.success(id)
                } catch (e: Exception) { result.error("sendMessage", e.message, null) }
            }
            "setTyping" -> scope.launch {
                client?.thread(directoryContact(call.argument<String>("to")!!))?.setTyping(call.argument<Boolean>("typing") ?: false)
                result.success(null)
            }
            "callHistory" -> scope.launch {
                try {
                    val h = client!!.callHistory(call.argument<Int>("limit") ?: 50)
                    result.success(h.map { mapOf("callId" to it.callId, "peer" to it.peer, "peerDisplayName" to it.peerDisplayName,
                        "direction" to it.direction.name.lowercase(), "outcome" to it.outcome, "durationSec" to it.durationSec, "at" to it.at) })
                } catch (e: Exception) { result.error("callHistory", e.message, null) }
            }
            "registerPush" -> scope.launch { runCatching { client?.push?.register(call.argument<String>("token") ?: "") }; result.success(null) }
            else -> result.notImplemented()
        }
    }

    // Native -> Dart: fetch a fresh token when the SDK needs one.
    private suspend fun tokenFromDart(): String = suspendCoroutine { cont ->
        main.post {
            channel.invokeMethod("getToken", null, object : MethodChannel.Result {
                override fun success(res: Any?) { cont.resume(res as? String ?: "") }
                override fun error(code: String, msg: String?, details: Any?) { cont.resume("") }
                override fun notImplemented() { cont.resume("") }
            })
        }
    }

    private fun directoryContact(sipUser: String): Contact =
        client?.directory?.firstOrNull { it.sipUser == sipUser || it.name == sipUser }
            ?: Contact(sipUser, sipUser, sipUser, UserType.CUSTOMER)

    private fun emit(map: Map<String, Any?>) { main.post { sink?.success(map) } }

    // ---- InCallListener -> EventChannel ----
    override fun onRegistrationChanged(state: RegistrationState) = emit(mapOf("event" to "registration", "state" to state.name.lowercase()))
    override fun onIncomingCall(call: Call) = emit(mapOf("event" to "incomingCall", "callId" to call.id,
        "from" to mapOf("name" to call.peer.name, "sipUser" to call.peer.sipUser, "displayName" to call.peer.displayName, "userType" to call.peer.userType.wire)))
    override fun onCallStateChanged(call: Call) = emit(mapOf("event" to "callState", "callId" to call.id, "state" to stateName(call.state)))
    override fun onCallQualityUpdated(quality: CallQuality) = emit(mapOf("event" to "quality",
        "quality" to mapOf("rttMs" to quality.rttMs, "jitterMs" to quality.jitterMs, "lossPct" to quality.lossPct, "mos" to quality.mos)))
    override fun onMessage(message: Message, thread: ChatThread) = emit(mapOf("event" to "message", "peerSip" to thread.peer.sipUser,
        "message" to mapOf("id" to message.id, "from" to message.from.name.lowercase(), "text" to message.text,
            "location" to message.location?.let { mapOf("lat" to it.lat, "lng" to it.lng, "label" to it.label) }, "status" to message.status.name.lowercase())))
    override fun onAudioRouteChanged(route: AudioRoute) = emit(mapOf("event" to "audioRoute", "route" to route.name.lowercase()))
    override fun onFailure(error: InCallException) = emit(mapOf("event" to "failure", "code" to error.javaClass.simpleName, "message" to (error.message ?: "")))

    private fun stateName(s: CallState): String = when (s) {
        is CallState.Initiating -> "initiating"; is CallState.Ringing -> "ringing"; is CallState.Connected -> "connected"
        is CallState.OnHold -> "onHold"; is CallState.Reconnecting -> "reconnecting"; is CallState.Ended -> "ended"
    }
}
