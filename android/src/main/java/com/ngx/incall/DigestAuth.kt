package com.ngx.incall

import java.security.MessageDigest
import java.util.UUID

/**
 * SIP digest authentication (RFC 2617 / RFC 3261, MD5). Builds the `Authorization` /
 * `Proxy-Authorization` header value in response to a challenge — what Kamailio's `pv_auth_check`
 * expects for REGISTER and INVITE. Pure protocol logic (no WebRTC), unit-tested.
 */
internal object DigestAuth {
    fun md5Hex(s: String): String =
        MessageDigest.getInstance("MD5").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

    data class Challenge(
        val realm: String,
        val nonce: String,
        val qop: String? = null,
        val opaque: String? = null,
        val algorithm: String? = null,
    )

    fun parseChallenge(header: String): Challenge? {
        val params = parseParams(header.replaceFirst(Regex("(?i)^Digest\\s+"), ""))
        val realm = params["realm"] ?: return null
        val nonce = params["nonce"] ?: return null
        return Challenge(realm, nonce, params["qop"], params["opaque"], params["algorithm"])
    }

    fun authorization(
        username: String, password: String, method: String, uri: String, challenge: Challenge,
        cnonce: String = UUID.randomUUID().toString().replace("-", ""), nc: String = "00000001",
    ): String {
        val ha1 = md5Hex("$username:${challenge.realm}:$password")
        val ha2 = md5Hex("$method:$uri")
        val fields = mutableListOf(
            "username=\"$username\"", "realm=\"${challenge.realm}\"",
            "nonce=\"${challenge.nonce}\"", "uri=\"$uri\"", "algorithm=MD5",
        )
        val response = if (challenge.qop?.contains("auth") == true) {
            fields.add("qop=auth"); fields.add("nc=$nc"); fields.add("cnonce=\"$cnonce\"")
            md5Hex("$ha1:${challenge.nonce}:$nc:$cnonce:auth:$ha2")
        } else {
            md5Hex("$ha1:${challenge.nonce}:$ha2")
        }
        fields.add("response=\"$response\"")
        challenge.opaque?.let { fields.add("opaque=\"$it\"") }
        return "Digest " + fields.joinToString(", ")
    }

    /** Split `a="x", b=y, c="z"` honouring quotes. */
    fun parseParams(s: String): Map<String, String> {
        val out = HashMap<String, String>()
        var key = StringBuilder(); var value = StringBuilder()
        var inKey = true; var inQuotes = false
        fun commit() {
            val k = key.toString().trim()
            if (k.isNotEmpty()) out[k.lowercase()] = value.toString().trim()
            key = StringBuilder(); value = StringBuilder(); inKey = true
        }
        for (ch in s) when {
            ch == '"' -> inQuotes = !inQuotes
            ch == '=' && inKey && !inQuotes -> inKey = false
            ch == ',' && !inQuotes -> commit()
            else -> if (inKey) key.append(ch) else value.append(ch)
        }
        commit()
        return out
    }
}
