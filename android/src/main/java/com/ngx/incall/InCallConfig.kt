package com.ngx.incall

/**
 * SDK configuration. The host app supplies the platform base URL and a `tokenProvider` that returns a
 * short-lived tenant JWT. The SDK never logs users in and stores no long-lived secret (FR-SDK-04): the
 * tenant's own backend authenticates the user and mints the token; the SDK calls `tokenProvider` on
 * start and again whenever the token has expired.
 */
class InCallConfig(
    val baseUrl: String,
    /** Register against TURN relay only (restrictive networks / diagnostics). */
    val forceRelay: Boolean = false,
    /** NFR-13: close the signalling connection while the app is in the background with no call (incoming calls
     *  arrive by FCM push instead) and reconnect when it returns. On by default. */
    val disconnectInBackground: Boolean = true,
    /** DEVELOPMENT ONLY: allow an `http://` baseUrl and `ws://` signalling (a local stack or lab server).
     *  Without it the SDK requires `https://` and `wss://`, so tokens and SIP credentials never travel in clear
     *  text. Never set this in a release build. */
    val allowInsecureTransport: Boolean = false,
    /** Suspending provider of a fresh tenant JWT. */
    val tokenProvider: suspend () -> String,
) {
    init {
        TransportSecurity.check(baseUrl, secure = "https", insecure = "http", allowInsecureTransport, "baseUrl")
    }
}

/** Scheme checks for the platform URL and the session's signalling URL. */
internal object TransportSecurity {
    /** Throws IllegalArgumentException unless [url] uses [secure], or [insecure] when [allowInsecure] is set. */
    fun check(url: String, secure: String, insecure: String, allowInsecure: Boolean, what: String) {
        val scheme = url.substringBefore("://", "").lowercase()
        val hasHost = url.substringAfter("://", "").isNotBlank()
        require(hasHost && (scheme == secure || (scheme == insecure && allowInsecure))) {
            if (scheme == insecure) "$what must use $secure:// ($insecure:// is allowed only with allowInsecureTransport = true, for development)"
            else "$what must be a $secure:// URL"
        }
    }
}
