package com.ngx.incall

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

/**
 * Thin HTTP client for the platform-api surface the SDK needs (contract §8). Every request carries the
 * tenant JWT as a Bearer token; on a 401 the client refreshes via the config's tokenProvider and
 * retries once. Fully implemented — only the media transport is stubbed.
 */
internal class PlatformApi(
    private val baseUrl: String,
    private val tokenProvider: suspend () -> String,
) {
    private val http = OkHttpClient()
    private val json = "application/json".toMediaType()
    @Volatile private var cachedToken: String? = null

    private suspend fun token(): String = cachedToken ?: refreshToken()
    suspend fun refreshToken(): String = tokenProvider().also { cachedToken = it }

    // ---- endpoints ----

    suspend fun fetchSession(): Session = parseSession(JSONObject(get("/api/session")))

    suspend fun callHistory(limit: Int = 50): List<HistoryEntry> {
        val arr = JSONObject(get("/api/history?limit=$limit")).getJSONArray("history")
        return (0 until arr.length()).map { parseHistory(arr.getJSONObject(it)) }
    }

    /** Emit a call/chat/location lifecycle event → CDR + webhook + push dispatch (FR-REP-02). */
    suspend fun emitEvent(type: String, callId: String?, to: String?, payload: JSONObject = JSONObject()) {
        val body = JSONObject().put("type", type)
        callId?.let { body.put("callId", it) }
        to?.let { body.put("to", it) }
        if (payload.length() > 0) body.put("payload", payload)
        runCatching { post("/api/events", body) }
    }

    /** Register this device's FCM token so the platform can wake the app on an incoming call. */
    suspend fun registerPush(deviceId: String, token: String) {
        post("/api/push/register", JSONObject().put("deviceId", deviceId).put("platform", "fcm").put("token", token))
    }

    suspend fun unregisterPush(deviceId: String) {
        post("/api/push/unregister", JSONObject().put("deviceId", deviceId))
    }

    /** FR-SDK-05: who of these users (extensions or usernames) is connected now; null = unknown. */
    suspend fun presence(users: List<String>): Map<String, Boolean?> {
        val q = java.net.URLEncoder.encode(users.joinToString(","), "UTF-8")
        val arr = JSONObject(get("/api/presence?users=$q")).optJSONArray("presence") ?: return emptyMap()
        return (0 until arr.length()).associate { i ->
            val o = arr.getJSONObject(i)
            o.getString("sipUser") to (if (o.isNull("online")) null else o.getBoolean("online"))
        }
    }

    suspend fun uploadDiagnostics(summary: JSONObject) {
        runCatching { post("/api/diag", JSONObject().put("summary", summary)) }
    }

    // ---- transport ----

    private suspend fun get(path: String): String = send(Request.Builder().url(baseUrl + path).get())

    private suspend fun post(path: String, body: JSONObject): String =
        send(Request.Builder().url(baseUrl + path).post(body.toString().toRequestBody(json)))

    private suspend fun send(builder: Request.Builder, retriedOn401: Boolean = false): String =
        withContext(Dispatchers.IO) {
            val req = builder.header("Authorization", "Bearer ${token()}")
                .header("X-SDK-Version", "android/${InCallSdkVersion.CURRENT}")   // FR-SDK-10
                .build()
            val resp = try { http.newCall(req).execute() }
            catch (e: Exception) { throw InCallException.Network(e.message ?: "io error") }
            resp.use {
                when {
                    it.isSuccessful -> it.body?.string().orEmpty()
                    it.code == 401 && !retriedOn401 -> { refreshToken(); send(builder, true) }
                    it.code == 401 -> throw InCallException.TokenExpired
                    else -> throw InCallException.Network("HTTP ${it.code}")
                }
            }
        }

    // ---- parsing ----

    private fun parseContacts(arr: JSONArray?): List<Contact> =
        if (arr == null) emptyList() else (0 until arr.length()).map {
            val o = arr.getJSONObject(it)
            Contact(o.getString("name"), o.getString("sipUser"),
                o.optString("displayName", o.getString("name")), UserType.from(o.optString("userType")))
        }

    private fun parseSession(o: JSONObject): Session {
        val f = o.optJSONObject("features") ?: JSONObject()
        return Session(
            tenant = o.getString("tenant"), user = o.getString("user"),
            userType = UserType.from(o.optString("userType")),
            features = Features(f.optBoolean("calling", true), f.optBoolean("chat", true),
                f.optBoolean("location", true), f.optBoolean("recording", false)),
            peers = parseContacts(o.optJSONArray("peers")),
            transferTargets = parseContacts(o.optJSONArray("transferTargets")),
            directory = parseContacts(o.optJSONArray("directory")),
            wss = o.getString("wss"), realm = o.getString("realm"),
            sipUser = o.getString("sipUser"), authUser = o.getString("authUser"),
            sipPassword = o.getString("sipPassword"),
            stun = o.optStringOrNull("stun"), turn = o.optStringOrNull("turn"),
            turnUser = o.optStringOrNull("turnUser"), turnPassword = o.optStringOrNull("turnPassword"),
        )
    }

    private fun parseHistory(o: JSONObject) = HistoryEntry(
        callId = o.getString("callId"), peer = o.getString("peer"),
        peerDisplayName = o.optString("peerDisplayName", o.getString("peer")),
        peerSipUser = o.optStringOrNull("peerSipUser"),
        direction = if (o.getString("direction") == "outgoing") CallDirection.OUTGOING else CallDirection.INCOMING,
        outcome = o.getString("outcome"), durationSec = o.optInt("durationSec"), at = o.optString("at"),
    )

    private fun JSONObject.optStringOrNull(key: String): String? =
        if (isNull(key) || !has(key)) null else optString(key)
}
