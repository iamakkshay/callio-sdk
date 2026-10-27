package com.ngx.incall

/**
 * Minimal SIP message model — parse a received message and build a request. Over WebSocket each text
 * frame is one SIP message (RFC 7118). Pure logic, unit-tested; no WebRTC.
 */
internal data class SipMessage(
    val startLine: String,
    val headers: List<Pair<String, String>>,
    val body: String,
) {
    val statusCode: Int?
        get() = if (startLine.startsWith("SIP/2.0")) startLine.split(" ").getOrNull(1)?.toIntOrNull() else null

    val method: String?
        get() = if (startLine.startsWith("SIP/2.0")) null else startLine.split(" ").firstOrNull()

    fun header(name: String): String? = headers.firstOrNull { it.first.equals(name, ignoreCase = true) }?.second

    companion object {
        fun parse(raw: String): SipMessage {
            val normalized = raw.replace("\r\n", "\n")
            val sep = normalized.indexOf("\n\n")
            val head = if (sep >= 0) normalized.substring(0, sep) else normalized
            val body = if (sep >= 0) normalized.substring(sep + 2) else ""
            val lines = head.split("\n").toMutableList()
            val startLine = if (lines.isEmpty()) "" else lines.removeAt(0)
            val headers = lines.mapNotNull { line ->
                val colon = line.indexOf(':')
                if (colon <= 0) null
                else line.substring(0, colon).trim() to line.substring(colon + 1).trim()
            }
            return SipMessage(startLine, headers, body)
        }

        fun buildRequest(
            method: String, requestURI: String,
            headers: List<Pair<String, String>>, body: String = "",
        ): String {
            val sb = StringBuilder("$method $requestURI SIP/2.0\r\n")
            for ((n, v) in headers) sb.append("$n: $v\r\n")
            sb.append("Content-Length: ${body.toByteArray().size}\r\n\r\n")
            sb.append(body)
            return sb.toString()
        }

        fun buildResponse(
            status: Int, reason: String,
            headers: List<Pair<String, String>>, body: String = "",
        ): String {
            val sb = StringBuilder("SIP/2.0 $status $reason\r\n")
            for ((n, v) in headers) sb.append("$n: $v\r\n")
            sb.append("Content-Length: ${body.toByteArray().size}\r\n\r\n")
            sb.append(body)
            return sb.toString()
        }
    }
}
