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
    /** Someone invites you into a 3-way call: show it, and call [InCallClient.joinConference] to join. */
    fun onConferenceInvite(invite: ConferenceInvite) {}
    /** The SDK dialled into a 3-way call by itself (the person you were talking to moved the call there). */
    fun onConferenceStarted(call: Call) {}
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
    /** This install's device id, sent as X-Device-Id: pass it to your server so it can request a token for this
     *  device only (POST /api/v1/tokens with deviceId). */
    val deviceId: String = stableDeviceId(appContext)
    private val api = PlatformApi(config.baseUrl, config.tokenProvider, deviceId)
    private val transport: SipTransport = transport.also { it.events = this }

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

    // ---- staying reachable: reconnect after a drop, with growing gaps (1, 2, 4 … 30 s) ----
    @Volatile private var offlineByChoice = false
    private var reconnectJob: kotlinx.coroutines.Job? = null
    private fun scheduleReconnect() {
        if (reconnectJob?.isActive == true) return
        reconnectJob = scope.launch {
            var attempt = 0
            while (wantsConnection && !offlineByChoice && registrationState != RegistrationState.REGISTERED) {
                kotlinx.coroutines.delay(minOf(30_000L, 1000L shl minOf(attempt, 5)))
                if (!wantsConnection || offlineByChoice) break
                runCatching { start() }
                attempt++
            }
        }
    }
    private var networkHooked = false
    private var lastNetwork: android.net.Network? = null
    /** A new network (Wi-Fi ↔ mobile data): the old connection is bound to the network that went away. */
    private fun hookNetwork() {
        if (networkHooked || Build.VERSION.SDK_INT < 24) return
        val cm = appContext.getSystemService(ConnectivityManager::class.java) ?: return
        networkHooked = true
        runCatching {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: android.net.Network) {
                    val changed = lastNetwork != null && lastNetwork != network
                    lastNetwork = network
                    if (changed && wantsConnection && !offlineByChoice) scope.launch { transport.dropConnection(); scheduleReconnect() }
                }
            })
        }
    }

    internal suspend fun onAppBackground() {
        if (!config.disconnectInBackground || !wantsConnection || currentCall != null) return
        offlineByChoice = true
        stopPresenceUpdates()
        transport.unregister()
        registrationState = RegistrationState.OFFLINE
    }
    internal suspend fun onAppForeground() {
        offlineByChoice = false
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
        hookNetwork()
        registrationState = RegistrationState.CONNECTING
        val s = api.fetchSession()
        try {
            TransportSecurity.check(s.wss, secure = "wss", insecure = "ws", config.allowInsecureTransport, "the session's signalling URL")
        } catch (e: IllegalArgumentException) {
            registrationState = RegistrationState.OFFLINE
            throw InCallException.Network(e.message ?: "insecure signalling URL")
        }
        session = s
        if (!s.features.calling && !s.features.chat) {
            registrationState = RegistrationState.OFFLINE
            return
        }
        transport.register(s, config.forceRelay)
    }

    suspend fun stop() {
        wantsConnection = false
        reconnectJob?.cancel()
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
        threads.getOrPut(contact.sipUser) { ChatThread(contact, transport) { body -> api.queueMessage(contact.sipUser, body) } }

    /** FR-CHAT-03: hand over messages the platform held while this user wasn't connected, then confirm them. */
    private val draining = java.util.concurrent.atomic.AtomicBoolean(false)
    private suspend fun drainHeldMessages() {
        if (!draining.compareAndSet(false, true)) return
        try {
            val held = runCatching { api.pendingMessages() }.getOrNull() ?: return
            val delivered = mutableListOf<Long>()
            for (m in held) {
                val from = m.fromSip ?: continue
                val b = m.body
                val key = b.optString("key").ifEmpty { "held:${m.id}" }
                when (b.optString("t")) {
                    "text" -> onMessage(from, b.optString("text"), null, key)
                    "file" -> parseAttachment(b.optJSONObject("attachment"))?.let { a -> onAttachment(from, a, key) }
                    "loc" -> b.optJSONObject("loc")?.let { l ->
                        onMessage(from, null, SharedLocation(l.optDouble("lat"), l.optDouble("lng"), l.optString("label", "Shared location")), key)
                    }
                }
                delivered += m.id   // anything we can't show (an unknown kind) is still confirmed, so it isn't offered forever
            }
            runCatching { api.ackMessages(delivered) }
        } finally { draining.set(false) }
    }

    /** Per-user call history (FR-CALL-08). */
    /**
     * Join a 3-way call you were invited to. Ends the current call first if there is one. The person who added
     * you is already there.
     */
    suspend fun joinConference(invite: ConferenceInvite): Call {
        currentCall?.let { runCatching { it.hangup() }; kotlinx.coroutines.delay(700) }
        return dialConference(invite.room)
    }

    private var pendingConference: String? = null

    /**
     * Bring [contact] into the current call as a 3-way call (FR-CALL-14), for example a rider adding the support
     * team. The person you're talking to follows you into the call, [contact] is invited, and you join it. To hand
     * the call over (a warm transfer), hang up once they're talking: the other two stay connected.
     * Throws if there's no connected call, or if [contact] isn't online (the current call is then left as it was).
     */
    suspend fun addToCall(contact: Contact) {
        val call = currentCall?.takeIf { it.state is CallState.Connected } ?: throw IllegalStateException("There's no connected call to add them to")
        val room = api.createConference(listOf(call.peer.sipUser, contact.sipUser))
        val names = org.json.JSONArray(listOf(call.peer.displayName, contact.displayName))
        fun invite(move: Boolean) = JSONObject().put("t", "conf").put("room", room).put("with", names).also { if (move) it.put("move", true) }.toString()
        try { transport.sendSignal(contact.sipUser, invite(move = false)) }   // first: if they're offline, nothing changes
        catch (e: InCallException.Network) { throw if (peerUnreachable(e)) InCallException.Network("${contact.displayName} isn't online") else e }
        transport.sendSignal(call.peer.sipUser, invite(move = true))
        pendingConference = room   // when this call ends, we dial the room (see onCallStateChanged)
        call.hangup()
    }

    private suspend fun dialConference(room: String): Call =
        dial(Contact(name = room, sipUser = room, displayName = "3-way call", userType = UserType.AGENT))

    suspend fun callHistory(limit: Int = 50): List<HistoryEntry> = api.callHistory(limit)

    // ---- helpers ----

    private fun contactForSip(sipUser: String): Contact =
        session?.directory?.firstOrNull { it.sipUser == sipUser }
            ?: Contact(sipUser, sipUser, sipUser, UserType.CUSTOMER)

    // ---- transport callbacks → listeners + event emission ----

    override fun onRegistrationChanged(state: RegistrationState) {
        registrationState = state
        // The connection dropped while the app wants to be reachable: reconnect (not when we went offline on purpose).
        if (state == RegistrationState.OFFLINE && wantsConnection && !offlineByChoice) scheduleReconnect()
        if (state == RegistrationState.REGISTERED && features.chat) scope.launch { drainHeldMessages() }   // on every (re)connect
    }

    override fun onIncomingCall(sipUser: String, callId: String) {
        val call = Call(callId, contactForSip(sipUser), CallDirection.INCOMING, CallState.Ringing, transport).also { it.audio = audio }
        currentCall = call
        emit { it.onIncomingCall(call) }
    }

    override fun onCallStateChanged(state: CallState, callId: String) {
        val call = currentCall ?: return
        if (call.id != callId) return
        val previous = call.state
        call.state = state
        emit { it.onCallStateChanged(call) }
        when (state) {
            is CallState.Ringing -> scope.launch { api.emitEvent("call.ringing", callId, call.peer.sipUser) }
            is CallState.Connected -> {
                audio.startCall()   // voice-call audio mode: echo cancellation, earpiece, Bluetooth
                if (previous !is CallState.OnHold) scope.launch { api.emitEvent("call.connected", callId, call.peer.sipUser) }
            }
            is CallState.Ended -> {
                audio.endCall()
                scope.launch { api.emitEvent("call.ended", callId, call.peer.sipUser,
                    JSONObject().put("reason", state.reason.wire).put("client", clientInfo())) }
                if (currentCall?.id == callId) currentCall = null
                // The person we were talking to moved the call into a 3-way call: follow them there.
                pendingConference?.let { room ->
                    pendingConference = null
                    scope.launch {
                        kotlinx.coroutines.delay(700)
                        runCatching { dialConference(room) }.onSuccess { c -> emit { it.onConferenceStarted(c) } }
                            .onFailure { e -> emit { it.onFailure(e as? InCallException ?: InCallException.Network(e.message ?: "conference")) } }
                    }
                }
            }
            else -> {}
        }
    }

    override fun onQualityUpdated(quality: CallQuality, callId: String) {
        currentCall?.quality = quality
        emit { it.onCallQualityUpdated(quality) }
    }

    override fun onAttachment(sipUser: String, attachment: Attachment, messageId: String) {
        val t = thread(contactForSip(sipUser))
        t.appendIncoming(messageId, null, null, attachment)
        t.messages.lastOrNull()?.let { msg -> emit { it.onMessage(msg, t) } }
    }

    /** Upload a photo or file for a chat (FR-CHAT-04); then send it with [ChatThread.sendAttachment]. */
    suspend fun uploadAttachment(name: String, type: String, bytes: ByteArray): Attachment = api.uploadAttachment(name, type, bytes)

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

    override fun onConferenceInvite(fromSip: String, room: String, move: Boolean, with: List<String>) {
        if (move && currentCall?.peer?.sipUser == fromSip) { pendingConference = room; return }   // we follow when they hang up
        val from = (session?.peers.orEmpty() + directory).firstOrNull { it.sipUser == fromSip }
            ?: Contact(name = fromSip, sipUser = fromSip, displayName = fromSip, userType = UserType.CUSTOMER)
        emit { it.onConferenceInvite(ConferenceInvite(room, from, with)) }
    }

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
