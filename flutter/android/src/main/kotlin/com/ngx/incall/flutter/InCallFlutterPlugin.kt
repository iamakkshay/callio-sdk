// Android bridge for the incall_flutter plugin: MethodChannel + EventChannel <-> the native com.ngx.incall SDK.
// Every Dart method in lib/src/incall.dart has a case here; every InCallListener callback becomes one event map
// { event: <name>, ...payload }. Errors come back as PlatformException with a stable code (contract section 7).
package com.ngx.incall.flutter

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.ngx.incall.AudioRoute
import com.ngx.incall.Call
import com.ngx.incall.CallQuality
import com.ngx.incall.CallState
import com.ngx.incall.ChatThread
import com.ngx.incall.ConferenceInvite
import com.ngx.incall.Contact
import com.ngx.incall.InCallClient
import com.ngx.incall.InCallConfig
import com.ngx.incall.InCallException
import com.ngx.incall.InCallListener
import com.ngx.incall.InCallSdkVersion
import com.ngx.incall.Message
import com.ngx.incall.PushService
import com.ngx.incall.RegistrationState
import com.ngx.incall.SharedLocation
import com.ngx.incall.UserType
import com.ngx.incall.telecom.InCallTelecom
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

class InCallFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
    ActivityAware, PluginRegistry.RequestPermissionsResultListener, InCallListener {

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var sink: EventChannel.EventSink? = null
    private var client: InCallClient? = null
    private val invites = mutableMapOf<String, ConferenceInvite>()   // room -> invite, until joined
    private var lastRoute: AudioRoute? = null

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissions: MethodChannel.Result? = null

    companion object {
        private const val PERMISSION_REQUEST = 0x0ca1
        /** The client the most recent `start` created, so a push handled on a background engine finds it. */
        @Volatile private var activeClient: InCallClient? = null
        @Volatile private var telecomInstalled = false
    }

    // ---- FlutterPlugin ----

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "incall_flutter").also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(binding.binaryMessenger, "incall_flutter/events").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        client?.removeListener(this)
        scope.cancel()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }

    // ---- ActivityAware (runtime permissions) ----

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity; activityBinding = binding; binding.addRequestPermissionsResultListener(this)
    }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this); activityBinding = null; activity = null
    }

    private fun wantedPermissions(): List<String> = buildList {
        add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
        if (Build.VERSION.SDK_INT >= 31) add(Manifest.permission.BLUETOOTH_CONNECT)
    }

    private fun granted(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun permissionReport(): Map<String, Boolean> = mapOf(
        "microphone" to granted(Manifest.permission.RECORD_AUDIO),
        "notifications" to (Build.VERSION.SDK_INT < 33 || granted(Manifest.permission.POST_NOTIFICATIONS)),
        "bluetooth" to (Build.VERSION.SDK_INT < 31 || granted(Manifest.permission.BLUETOOTH_CONNECT)),
    )

    private fun requestPermissions(result: MethodChannel.Result) {
        val missing = wantedPermissions().filterNot(::granted)
        val act = activity
        if (missing.isEmpty() || act == null || pendingPermissions != null) { result.success(permissionReport()); return }
        pendingPermissions = result
        act.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        pendingPermissions?.success(permissionReport())
        pendingPermissions = null
        return true
    }

    // ---- MethodChannel ----

    private fun run(result: MethodChannel.Result, body: suspend () -> Any?) {
        scope.launch {
            try { result.success(body()) } catch (e: Throwable) { result.error(errorCode(e), e.message ?: e.javaClass.simpleName, null) }
        }
    }

    private fun requireClient(): InCallClient = client ?: throw InCallException.NotRegistered
    private fun requireCall(): Call = client?.currentCall ?: throw NoActiveCall()
    private class NoActiveCall : Exception("no call in progress")

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> run(result) {
                val baseUrl = call.argument<String>("baseUrl") ?: throw IllegalArgumentException("baseUrl is required")
                client?.let { old -> old.removeListener(this); runCatching { old.stop() } }
                val config = InCallConfig(
                    baseUrl = baseUrl,
                    forceRelay = call.argument<Boolean>("forceRelay") ?: false,
                    disconnectInBackground = call.argument<Boolean>("disconnectInBackground") ?: true,
                    allowInsecureTransport = call.argument<Boolean>("allowInsecureTransport") ?: false,
                    tokenProvider = { tokenFromDart() },
                )
                val c = InCallClient(context, config)
                c.addListener(this)
                client = c
                activeClient = c
                if (call.argument<Boolean>("nativeCallUi") != false) {
                    InCallTelecom.install(context, c)
                    telecomInstalled = true
                    // Telecom takes over the audio router's change hook: keep audio-route events flowing to Dart.
                    val telecomHook = c.audio.onChange
                    c.audio.onChange = { route -> telecomHook?.invoke(route); onAudioRouteChanged(route) }
                }
                c.start()
                null
            }
            "stop" -> run(result) { client?.stop(); invites.clear(); null }
            "session" -> run(result) { client?.session?.let { s ->
                mapOf("tenant" to s.tenant, "user" to s.user, "sipUser" to s.sipUser, "userType" to s.userType.wire,
                    "features" to mapOf("calling" to s.features.calling, "chat" to s.features.chat,
                        "location" to s.features.location, "recording" to s.features.recording),
                    "directory" to s.directory.map(::contactMap), "peers" to s.peers.map(::contactMap),
                    "transferTargets" to s.transferTargets.map(::contactMap))
            } }
            "requestPermissions" -> requestPermissions(result)
            "sdkVersion" -> result.success(InCallSdkVersion.CURRENT)

            // calls
            "dial" -> run(result) {
                val sip = call.argument<String>("sipUser") ?: throw IllegalArgumentException("sipUser is required")
                requireClient().dial(contact(sip)).id
            }
            "answer" -> run(result) { requireCall().answer(); null }
            "decline" -> run(result) { client?.currentCall?.decline(); null }
            "cancel" -> run(result) { client?.currentCall?.cancel(); null }
            "hangup" -> run(result) { client?.currentCall?.hangup(); null }
            "setMuted" -> run(result) { requireCall().setMuted(call.argument<Boolean>("muted") ?: false); null }
            "setHold" -> run(result) { requireCall().setHold(call.argument<Boolean>("held") ?: false); null }
            "sendDtmf" -> run(result) { requireCall().sendDtmf(call.argument<String>("tone") ?: ""); null }
            "setAudioRoute" -> run(result) {
                val route = AudioRoute.valueOf((call.argument<String>("route") ?: "").uppercase())
                val active = client?.currentCall
                if (active != null) active.setAudioRoute(route) else requireClient().audio.set(route)
                null
            }
            "audioRoutes" -> run(result) {
                val audio = requireClient().audio
                mapOf("available" to audio.available.map { it.name.lowercase() }, "current" to audio.current.name.lowercase())
            }
            "transfer" -> run(result) { requireCall().transfer(contact(call.argument<String>("sipUser") ?: "")); null }
            "joinConference" -> run(result) {
                val room = call.argument<String>("room") ?: throw IllegalArgumentException("room is required")
                val invite = invites.remove(room) ?: ConferenceInvite(room, contact(room), emptyList())
                requireClient().joinConference(invite).id
            }

            // chat / location
            "sendMessage" -> run(result) {
                val thread = requireClient().thread(contact(call.argument<String>("to") ?: throw IllegalArgumentException("to is required")))
                val loc = call.argument<Map<String, Any?>>("location")
                if (loc != null) {
                    thread.sendLocation(SharedLocation((loc["lat"] as Number).toDouble(), (loc["lng"] as Number).toDouble(),
                        loc["label"] as? String ?: "Shared location")).id
                } else thread.send(call.argument<String>("text") ?: "").id
            }
            "setTyping" -> run(result) {
                client?.thread(contact(call.argument<String>("to") ?: ""))?.setTyping(call.argument<Boolean>("typing") ?: false); null
            }
            "messages" -> run(result) {
                val peer = call.argument<String>("peer") ?: ""
                client?.thread(contact(peer))?.messages?.map(::messageMap) ?: emptyList<Any>()
            }

            // presence
            "refreshPresence" -> run(result) {
                val c = requireClient()
                c.refreshPresence(call.argument<List<String>>("sipUsers")?.map(::contact))
                c.presence
            }
            "startPresenceUpdates" -> run(result) {
                requireClient().startPresenceUpdates(call.argument<Number>("everyMs")?.toLong() ?: 30_000L); null
            }
            "stopPresenceUpdates" -> run(result) { client?.stopPresenceUpdates(); null }

            // history / push
            "callHistory" -> run(result) {
                requireClient().callHistory(call.argument<Number>("limit")?.toInt() ?: 50).map {
                    mapOf("callId" to it.callId, "peer" to it.peer, "peerDisplayName" to it.peerDisplayName,
                        "peerSipUser" to it.peerSipUser, "direction" to it.direction.name.lowercase(), "outcome" to it.outcome,
                        "durationSec" to it.durationSec, "at" to it.at)
                }
            }
            "registerPush" -> run(result) { requireClient().push.register(call.argument<String>("token") ?: ""); null }
            "unregisterPush" -> run(result) { client?.push?.unregister(); null }
            "handlePush" -> run(result) {
                val data = call.argument<Map<String, String>>("data") ?: emptyMap()
                val push = PushService.parse(data)
                if (push != null && telecomInstalled && (client ?: activeClient) != null) {
                    InCallTelecom.reportIncoming(context, push); true
                } else false
            }
            else -> result.notImplemented()
        }
    }

    // Native -> Dart: fetch a fresh token when the SDK needs one. No answer in 20 s, or an empty one, is a token failure.
    private suspend fun tokenFromDart(): String {
        val d = CompletableDeferred<String?>()
        main.post {
            channel.invokeMethod("getToken", null, object : MethodChannel.Result {
                override fun success(res: Any?) { d.complete(res as? String) }
                override fun error(code: String, msg: String?, details: Any?) { d.complete(null) }
                override fun notImplemented() { d.complete(null) }
            })
        }
        val token = withTimeoutOrNull(20_000) { d.await() }
        return token?.takeIf { it.isNotEmpty() } ?: throw InCallException.TokenExpired
    }

    private fun contact(sipUser: String): Contact {
        val c = client
        return (c?.directory.orEmpty() + c?.session?.peers.orEmpty()).firstOrNull { it.sipUser == sipUser || it.name == sipUser }
            ?: Contact(sipUser, sipUser, sipUser, UserType.CUSTOMER)
    }

    private fun contactMap(c: Contact) =
        mapOf("name" to c.name, "sipUser" to c.sipUser, "displayName" to c.displayName, "userType" to c.userType.wire)

    private fun messageMap(m: Message) = mapOf("id" to m.id, "from" to m.from.name.lowercase(), "text" to m.text,
        "location" to m.location?.let { mapOf("lat" to it.lat, "lng" to it.lng, "label" to it.label) },
        "status" to m.status.name.lowercase())

    private fun emit(map: Map<String, Any?>) { main.post { sink?.success(map) } }

    // ---- InCallListener -> EventChannel ----

    override fun onRegistrationChanged(state: RegistrationState) =
        emit(mapOf("event" to "registration", "state" to state.name.lowercase()))

    override fun onIncomingCall(call: Call) =
        emit(mapOf("event" to "incomingCall", "callId" to call.id, "from" to contactMap(call.peer)))

    override fun onCallStateChanged(call: Call) {
        val s = call.state
        emit(mapOf("event" to "callState", "callId" to call.id, "state" to stateName(s),
            "reason" to (s as? CallState.Ended)?.reason?.wire, "direction" to call.direction.name.lowercase(),
            "peer" to contactMap(call.peer), "muted" to call.isMuted, "held" to call.isOnHold))
        if (s is CallState.Ended) lastRoute = null
    }

    override fun onCallQualityUpdated(quality: CallQuality) = emit(mapOf("event" to "quality", "callId" to client?.currentCall?.id,
        "quality" to mapOf("rttMs" to quality.rttMs, "jitterMs" to quality.jitterMs, "lossPct" to quality.lossPct, "mos" to quality.mos)))

    override fun onMessage(message: Message, thread: ChatThread) =
        emit(mapOf("event" to "message", "peerSip" to thread.peer.sipUser, "message" to messageMap(message)))

    override fun onMessageStatusChanged(message: Message) =
        emit(mapOf("event" to "messageStatus", "messageId" to message.id, "status" to message.status.name.lowercase()))

    override fun onAudioRouteChanged(route: AudioRoute) {
        if (route == lastRoute) return   // the SDK and the Telecom hook can both report one change
        lastRoute = route
        emit(mapOf("event" to "audioRoute", "route" to route.name.lowercase()))
    }

    override fun onPresenceChanged(presence: Map<String, Boolean>) = emit(mapOf("event" to "presence", "presence" to presence))

    override fun onConferenceInvite(invite: ConferenceInvite) {
        invites[invite.room] = invite
        emit(mapOf("event" to "conferenceInvite", "room" to invite.room, "from" to contactMap(invite.from), "with" to invite.with))
    }

    override fun onConferenceStarted(call: Call) =
        emit(mapOf("event" to "conferenceStarted", "callId" to call.id, "room" to call.peer.sipUser))

    override fun onFailure(error: InCallException) =
        emit(mapOf("event" to "failure", "code" to errorCode(error), "message" to (error.message ?: "")))

    private fun stateName(s: CallState): String = when (s) {
        is CallState.Initiating -> "initiating"; is CallState.Ringing -> "ringing"; is CallState.Connected -> "connected"
        is CallState.OnHold -> "onHold"; is CallState.Reconnecting -> "reconnecting"; is CallState.Ended -> "ended"
    }

    private fun errorCode(e: Throwable): String = when (e) {
        is InCallException.NotRegistered -> "notRegistered"
        is InCallException.MicPermission -> "micPermission"
        is InCallException.PeerUnreachable -> "peerUnreachable"
        is InCallException.Busy -> "busy"
        is InCallException.TokenExpired -> "tokenExpired"
        is InCallException.FeatureDisabled -> "featureDisabled"
        is InCallException.Network -> "network"
        is InCallException.MediaFailed -> "mediaFailed"
        is NoActiveCall -> "noActiveCall"
        is IllegalArgumentException -> "invalidArgument"
        is java.io.IOException -> "network"
        else -> "unknown"
    }
}
