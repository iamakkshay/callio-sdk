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
    /** Suspending provider of a fresh tenant JWT. */
    val tokenProvider: suspend () -> String,
)
