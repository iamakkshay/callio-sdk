package com.ngx.incall

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.UUID

/** Receives SDK events (contract §4). All methods have no-op defaults. */
interface InCallListener {
    fun onRegistrationChanged(state: RegistrationState) {}
    fun onIncomingCall(call: Call) {}
    fun onCallStateChanged(call: Call) {}
    fun onCallQualityUpdated(quality: CallQuality) {}
    fun onMessage(message: Message, thread: ChatThread) {}
    fun onMessageStatusChanged(message: Message) {}
    fun onFailure(error: InCallException) {}
    /** The call's audio moved (speaker, earpiece, Bluetooth), by the user or by a headset coming or going. */
    fun onAudioRouteChanged(route: AudioRoute) {}
    /** FR-SDK-05: contacts came online or went offline (sipUser → connected), while presence updates run. */
    fun onPresenceChanged(presence: Map<String, Boolean>) {}
}

/**
 * The headless entry point (contract §3). One long-lived instance per signed-in user: it owns
 * registration, the session, the active call, and chat threads. An optional prebuilt UI layer (not in
 * this skeleton) can be built on top.
 */
class InCallClient internal constructor(
    context: Context,
    private val config: InCallConfig,
    private val scope: CoroutineScope,
    transport: SipTransport,
) : SipTransportEvents {

    /** Public entry point. Uses WebRTC calls when the media layer is compiled in (the published SDK), else
     *  the signalling-only transport (registration and chat). */
    constructor(context: Context, config: InCallConfig, scope: CoroutineScope = CoroutineScope(Dispatchers.Main))
        : this(context, config, scope, defaultTransport(context))

    private val appContext = context.applicationContext
    private val api = PlatformApi(config.baseUrl, config.tokenProvider)
    private val transport: SipTransport = transport.also { it.events = this }
    private val deviceId = stableDeviceId(appContext)

    val push = PushService(api, deviceId)

    /** Call audio routing: `audio.available`, `audio.current`, `audio.set(AudioRoute.SPEAKER)` (FR-CALL-04). */
    val audio = AudioRouter(appContext).also { r -> r.onChange = { route -> emit { it.onAudioRouteChanged(route) } } }

    private val listeners = mutableListOf<InCallListener>()
    fun addListener(l: InCallListener) { listeners.add(l) }
    fun removeListener(l: InCallListener) { listeners.remove(l) }
    private fun emit(block: (InCallListener) -> Unit) { listeners.toList().forEach(block) }

    var registrationState: RegistrationState = RegistrationState.OFFLINE
        private set(value) { field = value; emit { it.onRegistrationChanged(value) } }

    var session: Session? = null
        private set
    var currentCall: Call? = null
        private set

    val features: Features get() = session?.features ?: Features()
    val userType: UserType? get() = session?.userType
    val directory: List<Contact> get() = session?.directory ?: emptyList()

    private val threads = mutableMapOf<String, ChatThread>()   // keyed by peer sipUser

    // ---- presence (FR-SDK-05) ----
    /** Who is connected now (sipUser → true/false), as of the last refresh. */
    var presence: Map<String, Boolean> = emptyMap()
        private set
    private var presenceJob: kotlinx.coroutines.Job? = null

    /** Ask once for these contacts (default: the directory); notifies listeners if anything changed. */
    suspend fun refreshPresence(contacts: List<Contact>? = null) {
        val users = (contacts ?: directory).map { it.sipUser }
        if (users.isEmpty()) return
        val got = runCatching { api.presence(users) }.getOrNull() ?: return
        val next = presence.toMutableMap().apply { for ((k, v) in got) if (v != null) put(k, v) }
        if (next != presence) { presence = next; emit { it.onPresenceChanged(next) } }
    }
    fun startPresenceUpdates(everyMs: Long = 30_000) {
        presenceJob?.cancel()
        presenceJob = scope.launch { while (true) { refreshPresence(); kotlinx.coroutines.delay(everyMs) } }
    }
    fun stopPresenceUpdates() { presenceJob?.cancel(); presenceJob = null }

    // ---- background (NFR-13): no socket while in the background without a call; pushes ring instead ----
    private var wantsConnection = false
    private var startedActivities = 0
    private var lifecycleHooked = false

    internal suspend fun onAppBackground() {
        if (!config.disconnectInBackground || !wantsConnection || currentCall != null) return
        stopPresenceUpdates()
        transport.unregister()
        registrationState = RegistrationState.OFFLINE
    }
    internal suspend fun onAppForeground() {
        if (!config.disconnectInBackground || !wantsConnection || registrationState != RegistrationState.OFFLINE) return
        runCatching { start() }
    }
    private fun hookLifecycle() {
        val app = appContext as? android.app.Application ?: return
        lifecycleHooked = true
        app.registerActivityLifecycleCallbacks(object : android.app.Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(a: android.app.Activity) { if (startedActivities++ == 0) scope.launch { onAppForeground() } }
            override fun onActivityStopped(a: android.app.Activity) { if (--startedActivities == 0) scope.launch { onAppBackground() } }
            override fun onActivityCreated(a: android.app.Activity, b: android.os.Bundle?) {}
            override fun onActivityResumed(a: android.app.Activity) {}
            override fun onActivityPaused(a: android.app.Activity) {}
            override fun onActivitySaveInstanceState(a: android.app.Activity, b: android.os.Bundle) {}
            override fun onActivityDestroyed(a: android.app.Activity) {}
        })
    }

    /** Fetch the session and register. */
    suspend fun start() {
        wantsConnection = true
        if (!lifecycleHooked) hookLifecycle()
        registrationState = RegistrationState.CONNECTING
        val s = api.fetchSession()
        session = s
        if (!s.features.calling && !s.features.chat) {
            registrationState = RegistrationState.OFFLINE
            return
        }
        transport.register(s, config.forceRelay)
    }

    suspend fun stop() {
        wantsConnection = false
        stopPresenceUpdates()
        transport.unregister()
        session = null
        currentCall = null
        threads.clear()
    }

    /** Place a call. Honours the tenant's calling feature flag (FR-MT). */
    suspend fun dial(contact: Contact): Call {
        if (!features.calling) throw InCallException.FeatureDisabled("calling")
        if (registrationState != RegistrationState.REGISTERED) throw InCallException.NotRegistered
        api.emitEvent("call.initiating", null, contact.sipUser)
        val callId = transport.dial(contact.sipUser)
        return Call(callId, contact, CallDirection.OUTGOING, CallState.Initiating, transport).also { it.audio = audio; currentCall = it }
    }

    fun thread(contact: Contact): ChatThread =
        threads.getOrPut(contact.sipUser) { ChatThread(contact, transport) }

    /** Per-user call history (FR-CALL-08). */
    suspend fun callHistory(limit: Int = 50): List<HistoryEntry> = api.callHistory(limit)

    // ---- helpers ----

    private fun contactForSip(sipUser: String): Contact =
        session?.directory?.firstOrNull { it.sipUser == sipUser }
            ?: Contact(sipUser, sipUser, sipUser, UserType.CUSTOMER)

    // ---- transport callbacks → listeners + event emission ----

    override fun onRegistrationChanged(state: RegistrationState) { registrationState = state }

    override fun onIncomingCall(sipUser: String, callId: String) {
        val call = Call(callId, contactForSip(sipUser), CallDirection.INCOMING, CallState.Ringing, transport).also { it.audio = audio }
        currentCall = call
        emit { it.onIncomingCall(call) }
    }

    override fun onCallStateChanged(state: CallState, callId: String) {
        val call = currentCall ?: return
        if (call.id != callId) return
        call.state = state
        emit { it.onCallStateChanged(call) }
        when (state) {
            is CallState.Ringing -> scope.launch { api.emitEvent("call.ringing", callId, call.peer.sipUser) }
            is CallState.Connected -> scope.launch { api.emitEvent("call.connected", callId, call.peer.sipUser) }
            is CallState.Ended -> {
                scope.launch { api.emitEvent("call.ended", callId, call.peer.sipUser,
                    JSONObject().put("reason", state.reason.wire).put("client", clientInfo())) }
                if (currentCall?.id == callId) currentCall = null
            }
            else -> {}
        }
    }

    override fun onQualityUpdated(quality: CallQuality, callId: String) {
        currentCall?.quality = quality
        emit { it.onCallQualityUpdated(quality) }
    }

    override fun onMessage(sipUser: String, text: String?, location: SharedLocation?, messageId: String) {
        val t = thread(contactForSip(sipUser))
        t.appendIncoming(messageId, text, location)
        t.messages.lastOrNull()?.let { msg -> emit { it.onMessage(msg, t) } }
    }

    override fun onMessageStatusChanged(messageId: String, status: MessageStatus) {
        for (t in threads.values) {
            t.updateStatus(messageId, status)
            t.messages.firstOrNull { it.id == messageId }?.let { msg -> emit { it.onMessageStatusChanged(msg) }; return }
        }
    }

    override fun onFailure(error: InCallException) { emit { it.onFailure(error) } }

    private companion object {
        // The WebRTC transport lives in webrtc/, which only builds with libwebrtc, so src/main can't name it.
        // Load it by name when it's there; consumer-rules.pro keeps the class through the host app's R8.
        fun defaultTransport(context: Context): SipTransport =
            runCatching {
                Class.forName("com.ngx.incall.WebRtcSignallingSipTransport")
                    .getDeclaredConstructor(Context::class.java)
                    .apply { isAccessible = true }
                    .newInstance(context.applicationContext) as SipTransport
            }.getOrElse { SignallingSipTransport() }

        fun stableDeviceId(context: Context): String {
            val prefs = context.getSharedPreferences("incall", Context.MODE_PRIVATE)
            return prefs.getString("deviceId", null) ?: UUID.randomUUID().toString().also {
                prefs.edit().putString("deviceId", it).apply()
            }
        }
    }

    // Device facts sent with call.ended for the call-quality report by OS / app version / network (FR-REP-06).
    private fun clientInfo(): JSONObject {
        val info = JSONObject().put("os", "Android").put("osVersion", Build.VERSION.RELEASE)
        runCatching { appContext.packageManager.getPackageInfo(appContext.packageName, 0).versionName }.getOrNull()?.let { info.put("appVersion", it) }
        runCatching {
            val cm = appContext.getSystemService(ConnectivityManager::class.java)
            val caps = cm.getNetworkCapabilities(cm.activeNetwork)
            when {
                caps == null -> null
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                else -> "other"
            }
        }.getOrNull()?.let { info.put("network", it) }
        return info
    }
}
