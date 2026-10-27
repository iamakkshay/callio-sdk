// Host-app glue for the native call experience (FR-CALL-02/03). The Telecom side (ConnectionService, incoming-call
// notification, audio routing) is in the SDK (com.ngx.incall.telecom.InCallTelecom); the host app only owns Firebase.
//
// Manifest (host app):
//   <service android:name=".IncallMessagingService" android:exported="false">
//     <intent-filter><action android:name="com.google.firebase.MESSAGING_EVENT"/></intent-filter>
//   </service>
// Application.onCreate:
//   InCallTelecom.install(this, inCallClient)
// Runtime permissions to request: RECORD_AUDIO, POST_NOTIFICATIONS (13+), BLUETOOTH_CONNECT (12+).
package com.ngx.incall.example

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.ngx.incall.PushService
import com.ngx.incall.telecom.InCallTelecom
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** Receives the FCM token and incoming-call pushes. */
class IncallMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        CoroutineScope(Dispatchers.IO).launch { runCatching { MyApp.inCallClient.push.register(token) } }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val push = PushService.parse(message.data) ?: return
        InCallTelecom.reportIncoming(applicationContext, push)   // rings with the full-screen call notification
    }
}
