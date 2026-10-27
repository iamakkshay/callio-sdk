package com.ngx.incall

import org.json.JSONObject

/**
 * Push registration (FR-SDK-06 / FR-CALL-03). The host app obtains an FCM registration token and hands
 * it here; the SDK registers it with the platform so a backgrounded/killed app can be woken to ring.
 * When the platform delivers the high-priority data message, the app reports the call to a self-managed
 * [android.telecom.ConnectionService] and then the SDK pulls the session and connects media.
 *
 * The FirebaseMessagingService + ConnectionService wiring lives in the host app (it needs the app's
 * manifest + Firebase config); this service only owns the platform registration half.
 */
class PushService internal constructor(
    private val api: PlatformApi,
    private val deviceId: String,
) {
    /** Call from `FirebaseMessagingService.onNewToken`. */
    suspend fun register(fcmToken: String) = api.registerPush(deviceId, fcmToken)

    suspend fun unregister() = api.unregisterPush(deviceId)

    /** Shape of the wake-up payload the platform sends (see repos/push.js `notifyIncomingCall`). */
    data class IncomingCallPush(val callId: String, val fromDisplayName: String, val tenant: String)

    companion object {
        /** Parse the FCM data payload into a typed push. Returns null if it isn't an incoming call. */
        fun parse(data: Map<String, String>): IncomingCallPush? {
            // The platform sends the notification object under "notification" (JSON) in the data map.
            val raw = data["notification"] ?: return null
            val n = runCatching { JSONObject(raw) }.getOrNull() ?: return null
            if (n.optString("type") != "incoming_call") return null
            val from = n.optJSONObject("from")
            return IncomingCallPush(
                callId = n.optString("callId"),
                fromDisplayName = from?.optString("displayName") ?: "Caller",
                tenant = n.optString("tenant"),
            )
        }
    }
}
