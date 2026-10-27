package com.clarigo.callio.demo

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import com.ngx.incall.SharedLocation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Gets a Callio token for the demo. It uses the platform's test sign-in (POST /api/login), which works for
 * sandbox organisations from the developer portal. A real app never sends passwords to Callio: your own
 * server signs the user in and calls POST /api/v1/tokens with your API key, and the app asks your server.
 */
object DemoLogin {
    suspend fun token(baseUrl: String, org: String, username: String, password: String): String = withContext(Dispatchers.IO) {
        val conn = URL("$baseUrl/api/login").openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.connectTimeout = 10_000
            conn.readTimeout = 10_000
            conn.setRequestProperty("Content-Type", "application/json")
            val body = JSONObject().put("tenant", org).put("username", username).put("password", password)
            conn.outputStream.use { it.write(body.toString().toByteArray()) }
            val ok = conn.responseCode in 200..299
            val text = (if (ok) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() }.orEmpty()
            val json = runCatching { JSONObject(text) }.getOrNull()
            if (!ok) throw IOException(json?.optString("error")?.takeIf { it.isNotEmpty() } ?: "Sign-in failed (${conn.responseCode})")
            json?.optString("token")?.takeIf { it.isNotEmpty() } ?: throw IOException("No token in the sign-in response")
        } finally {
            conn.disconnect()
        }
    }
}

/** The device's last known position, for "share location" in chat. Null without permission or a fix. */
@SuppressLint("MissingPermission")
fun lastLocation(context: Context): SharedLocation? {
    val granted = listOf(android.Manifest.permission.ACCESS_FINE_LOCATION, android.Manifest.permission.ACCESS_COARSE_LOCATION)
        .any { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    if (!granted) return null
    val lm = context.getSystemService(LocationManager::class.java) ?: return null
    val fix = lm.getProviders(true).mapNotNull { lm.getLastKnownLocation(it) }.maxByOrNull { it.time } ?: return null
    return SharedLocation(fix.latitude, fix.longitude, "My location")
}
