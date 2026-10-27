package com.ngx.incall.telecom

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import com.ngx.incall.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * The native call experience on Android (FR-CALL-02/03/04): calls run as self-managed Telecom calls, so the
 * system knows a call is in progress (other apps' audio pauses, Bluetooth and car kits answer and hang up,
 * a cellular call can hold ours), and an incoming call rings with a full-screen call notification, even from a
 * killed app when a push arrives.
 *
 *   InCallTelecom.install(context, client)                  // Application.onCreate
 *   InCallTelecom.reportIncoming(context, push)              // from FirebaseMessagingService.onMessageReceived
 *   InCallTelecom.startCall(context, contact)                // outgoing calls through Telecom too
 *
 * The library manifest declares the ConnectionService, the notification receiver and MANAGE_OWN_CALLS; the host
 * app asks for POST_NOTIFICATIONS (Android 13+) and RECORD_AUDIO at runtime.
 */
object InCallTelecom {
    internal const val SCHEME = "callio"
    internal const val CHANNEL = "callio_incoming"
    internal const val NOTIFICATION_ID = 0x0ca1
    @Volatile internal var client: InCallClient? = null
    internal lateinit var appContext: Context
    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    internal val byCallId = mutableMapOf<String, InCallConnection>()
    internal var pushed: InCallConnection? = null          // created from a push, waiting for the INVITE
    internal val outgoing = mutableMapOf<String, Contact>() // sipUser → contact, until Telecom creates the connection

    /** App icon / name shown in the incoming-call notification. */
    var smallIcon: Int = android.R.drawable.sym_call_incoming
    var accountLabel: String = "Calls"

    fun handle(context: Context) =
        PhoneAccountHandle(ComponentName(context, InCallConnectionService::class.java), "callio")

    /** Register the self-managed phone account and follow the client's calls. Call once at startup. */
    fun install(context: Context, client: InCallClient) {
        appContext = context.applicationContext
        this.client = client
        val tm = appContext.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        tm.registerPhoneAccount(PhoneAccount.builder(handle(appContext), accountLabel)
            .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
            .setSupportedUriSchemes(listOf(SCHEME))
            .build())
        client.addListener(listener)
        client.audio.onChange = { route -> byCallId.values.forEach { it.lastRoute = route } }
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = appContext.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(null, null)   // Telecom / the app plays the ringtone
            })
        }
    }

    /** A VoIP push arrived: ring now; the call attaches when its INVITE reaches the SDK. */
    fun reportIncoming(context: Context, push: PushService.IncomingCallPush) =
        addIncoming(context, push.callId, push.fromDisplayName, fromPush = true)

    /** Place a call through Telecom (needs MANAGE_OWN_CALLS, declared by the library). */
    fun startCall(context: Context, contact: Contact) {
        outgoing[contact.sipUser] = contact
        val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        tm.placeCall(Uri.fromParts(SCHEME, contact.sipUser, null), Bundle().apply {
            putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle(context))
        })
    }

    internal fun addIncoming(context: Context, callId: String, name: String, fromPush: Boolean) {
        val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        tm.addNewIncomingCall(handle(context), Bundle().apply {
            putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.fromParts(SCHEME, callId, null))
            putString("callId", callId); putString("name", name); putBoolean("fromPush", fromPush)
        })
    }

    private val listener = object : InCallListener {
        override fun onIncomingCall(call: Call) {
            val p = pushed
            if (p != null) { pushed = null; byCallId.remove(p.callId); p.callId = call.id; byCallId[call.id] = p }
            else if (call.id !in byCallId) addIncoming(appContext, call.id, call.peer.displayName, fromPush = false)
        }

        override fun onCallStateChanged(call: Call) {
            val conn = byCallId[call.id] ?: return
            when (val s = call.state) {
                is CallState.Connected -> { conn.setActive(); client?.audio?.startCall(); cancelNotification() }
                is CallState.OnHold -> conn.setOnHold()
                is CallState.Ended -> conn.end(when (s.reason) {
                    CallEndReason.DECLINED -> DisconnectCause.REJECTED
                    CallEndReason.MISSED, CallEndReason.NO_ANSWER -> DisconnectCause.MISSED
                    CallEndReason.BUSY -> DisconnectCause.BUSY
                    CallEndReason.UNREACHABLE -> DisconnectCause.ERROR
                    CallEndReason.ENDED -> DisconnectCause.REMOTE
                })
                else -> {}
            }
        }
    }

    internal fun cancelNotification() =
        appContext.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)

    /** Full-screen, CallStyle (Android 12+) incoming-call notification with Answer / Decline. */
    internal fun showIncomingNotification(conn: InCallConnection) {
        val ctx = appContext
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)?.apply { putExtra("callio.callId", conn.callId) }
        val fullScreen = PendingIntent.getActivity(ctx, 1, open ?: Intent(), flags)
        fun action(a: String, code: Int) = PendingIntent.getBroadcast(ctx, code, Intent(ctx, CallActionReceiver::class.java).setAction(a).putExtra("callId", conn.callId), flags)
        val answer = action(CallActionReceiver.ANSWER, 2)
        val decline = action(CallActionReceiver.DECLINE, 3)
        val b = (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(ctx))
            .setSmallIcon(smallIcon)
            .setContentTitle(conn.name)
            .setContentText("Incoming call")
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setFullScreenIntent(fullScreen, true)
        if (Build.VERSION.SDK_INT >= 31) {
            b.setStyle(Notification.CallStyle.forIncomingCall(Person.Builder().setName(conn.name).setImportant(true).build(), decline, answer))
        } else {
            b.addAction(Notification.Action.Builder(null, "Decline", decline).build())
             .addAction(Notification.Action.Builder(null, "Answer", answer).build())
        }
        ctx.getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, b.build())
    }
}

/** One self-managed Telecom call; the system's and the notification's actions route to the SDK. */
class InCallConnection internal constructor(var callId: String, val name: String) : Connection() {
    internal var lastRoute: AudioRoute? = null
    private val client get() = InCallTelecom.client
    private val scope get() = InCallTelecom.scope

    init {
        connectionProperties = PROPERTY_SELF_MANAGED
        connectionCapabilities = CAPABILITY_HOLD or CAPABILITY_SUPPORT_HOLD or CAPABILITY_MUTE
        audioModeIsVoip = true
        setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED)
    }

    override fun onShowIncomingCallUi() = InCallTelecom.showIncomingNotification(this)

    override fun onAnswer() {
        InCallTelecom.cancelNotification()
        scope.launch {
            runCatching { client?.currentCall?.takeIf { it.id == callId }?.answer() ?: error("call not here yet") }
                .onSuccess { setActive(); client?.audio?.startCall() }
                .onFailure { end(DisconnectCause.ERROR) }
        }
    }

    override fun onReject() {
        scope.launch { client?.currentCall?.takeIf { it.id == callId }?.decline() }
        end(DisconnectCause.REJECTED)
    }

    override fun onDisconnect() {
        scope.launch { client?.currentCall?.takeIf { it.id == callId }?.hangup() }
        end(DisconnectCause.LOCAL)
    }

    override fun onAbort() = onDisconnect()
    override fun onHold() { scope.launch { client?.currentCall?.setHold(true) }; setOnHold() }
    override fun onUnhold() { scope.launch { client?.currentCall?.setHold(false) }; setActive() }
    override fun onPlayDtmfTone(c: Char) { scope.launch { client?.currentCall?.sendDtmf(c.toString()) } }

    @Deprecated("Telecom's audio state; still delivered on every supported API level")
    override fun onCallAudioStateChanged(state: CallAudioState?) {
        val route = when (state?.route) {
            CallAudioState.ROUTE_SPEAKER -> AudioRoute.SPEAKER
            CallAudioState.ROUTE_BLUETOOTH -> AudioRoute.BLUETOOTH
            null -> return
            else -> AudioRoute.EARPIECE
        }
        if (route != lastRoute) { lastRoute = route; client?.audio?.changed() }
        state?.isMuted?.let { m -> scope.launch { client?.currentCall?.let { if (it.isMuted != m) it.setMuted(m) } } }
    }

    internal fun end(cause: Int) {
        InCallTelecom.cancelNotification()
        if (state == STATE_DISCONNECTED) return
        setDisconnected(DisconnectCause(cause))
        destroy()
        InCallTelecom.byCallId.remove(callId)
        if (InCallTelecom.pushed === this) InCallTelecom.pushed = null
        if (InCallTelecom.byCallId.isEmpty()) client?.audio?.endCall()
    }
}

/** The ConnectionService Telecom calls into (declared in the library manifest). */
class InCallConnectionService : ConnectionService() {
    override fun onCreateIncomingConnection(account: PhoneAccountHandle?, request: ConnectionRequest?): Connection {
        val extras = request?.extras
        val callId = extras?.getString("callId") ?: ""
        val conn = InCallConnection(callId, extras?.getString("name") ?: "Caller")
        conn.setAddress(Uri.fromParts(InCallTelecom.SCHEME, callId, null), TelecomManager.PRESENTATION_ALLOWED)
        conn.setRinging()
        InCallTelecom.byCallId[callId] = conn
        if (extras?.getBoolean("fromPush") == true) {
            InCallTelecom.pushed = conn
            // Register so the INVITE can arrive; end the ring if the caller gives up before it does.
            InCallTelecom.scope.launch {
                runCatching { InCallTelecom.client?.start() }
                kotlinx.coroutines.delay(30_000)
                if (InCallTelecom.pushed === conn) conn.end(DisconnectCause.MISSED)
            }
        }
        return conn
    }

    override fun onCreateOutgoingConnection(account: PhoneAccountHandle?, request: ConnectionRequest?): Connection {
        val sipUser = request?.address?.schemeSpecificPart ?: ""
        val contact = InCallTelecom.outgoing.remove(sipUser) ?: Contact(sipUser, sipUser, sipUser, UserType.CUSTOMER)
        val conn = InCallConnection("pending:$sipUser", contact.displayName)
        conn.setAddress(request?.address, TelecomManager.PRESENTATION_ALLOWED)
        conn.setDialing()
        InCallTelecom.scope.launch {
            runCatching { InCallTelecom.client!!.dial(contact) }
                .onSuccess { call -> conn.callId = call.id; InCallTelecom.byCallId[call.id] = conn; InCallTelecom.client?.audio?.startCall() }
                .onFailure { conn.end(DisconnectCause.ERROR) }
        }
        return conn
    }

    override fun onCreateIncomingConnectionFailed(account: PhoneAccountHandle?, request: ConnectionRequest?) {
        // Telecom refused (e.g. an emergency call is active): decline so the caller isn't left ringing.
        InCallTelecom.scope.launch { InCallTelecom.client?.currentCall?.decline() }
    }

    override fun onCreateOutgoingConnectionFailed(account: PhoneAccountHandle?, request: ConnectionRequest?) {
        InCallTelecom.outgoing.remove(request?.address?.schemeSpecificPart ?: "")
    }
}

/** Answer / Decline from the incoming-call notification. */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val conn = InCallTelecom.byCallId[intent.getStringExtra("callId") ?: return] ?: return
        when (intent.action) { ANSWER -> conn.onAnswer(); DECLINE -> conn.onReject() }
    }
    companion object {
        const val ANSWER = "com.ngx.incall.ANSWER"
        const val DECLINE = "com.ngx.incall.DECLINE"
    }
}
