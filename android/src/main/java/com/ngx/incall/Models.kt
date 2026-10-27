package com.ngx.incall

/**
 * Public value types shared across the SDK. These mirror the platform's /api/session shape and the
 * reference web engine's state surface (public/engine/sip.js), so native and web behave identically.
 */

enum class RegistrationState { CONNECTING, REGISTERED, OFFLINE }

/** Who the user is to the platform (carried in the JWT, enforced server-side) — FR-SDK-13. */
enum class UserType(val wire: String) {
    CUSTOMER("customer"), AGENT("agent");
    companion object { fun from(s: String?) = entries.firstOrNull { it.wire == s } ?: CUSTOMER }
}

/** Per-tenant feature flags; the SDK and UI honour these (FR-MT / FR-ADM). */
data class Features(
    val calling: Boolean = true,
    val chat: Boolean = true,
    val location: Boolean = true,
    val recording: Boolean = false,
)

/** A person the user can call or message. */
data class Contact(
    val name: String,          // stable username / tenant user id
    val sipUser: String,       // SIP extension
    val displayName: String,
    val userType: UserType,
)

enum class CallDirection { INCOMING, OUTGOING }

/** Why a call ended — mirrors the reference engine's end reasons (FR-CALL-05). */
enum class CallEndReason(val wire: String) {
    ENDED("ended"), DECLINED("declined"), MISSED("missed"),
    NO_ANSWER("no-answer"), BUSY("busy"), UNREACHABLE("unreachable");
    companion object { fun from(s: String?) = entries.firstOrNull { it.wire == s } ?: ENDED }
}

/** Call lifecycle states (FR-CALL-05). */
sealed class CallState {
    data object Initiating : CallState()
    data object Ringing : CallState()
    data object Connected : CallState()
    data object OnHold : CallState()
    data object Reconnecting : CallState()
    data class Ended(val reason: CallEndReason) : CallState()
}

/** Live call quality (FR-CALL-11). `mos` is null until MOS scoring lands. */
data class CallQuality(
    val rttMs: Int? = null,
    val jitterMs: Int? = null,
    val lossPct: Double? = null,
    val mos: Double? = null,
)

/** Where call audio is routed (FR-CALL-04). Mapped to AudioManager / ConnectionService by the transport. */
enum class AudioRoute { SPEAKER, EARPIECE, BLUETOOTH }

enum class MessageSender { ME, PEER }
enum class MessageStatus { SENDING, SENT, DELIVERED, READ, FAILED }

data class SharedLocation(val lat: Double, val lng: Double, val label: String)

/** Someone invites this user into a 3-way call. Join with [InCallClient.joinConference]. */
data class ConferenceInvite(val room: String, val from: Contact, val with: List<String>)

data class Message(
    val id: String,
    val from: MessageSender,
    val text: String? = null,
    val location: SharedLocation? = null,
    val status: MessageStatus = MessageStatus.SENDING,
)

/** One row of per-user call history (FR-CALL-08), from GET /api/history. */
data class HistoryEntry(
    val callId: String,
    val peer: String,
    val peerDisplayName: String,
    val peerSipUser: String?,
    val direction: CallDirection,
    val outcome: String,
    val durationSec: Int,
    val at: String,            // ISO-8601
)

/** Errors surfaced to the integrator — stable type for programmatic handling (contract §7). */
sealed class InCallException(message: String) : Exception(message) {
    data object NotRegistered : InCallException("not registered")
    data object MicPermission : InCallException("microphone permission denied")
    data object PeerUnreachable : InCallException("peer unreachable")
    data object Busy : InCallException("peer busy")
    data object TokenExpired : InCallException("token expired")
    data class FeatureDisabled(val feature: String) : InCallException("feature disabled: $feature")
    data class Network(val reason: String) : InCallException("network: $reason")
    data class MediaFailed(val reason: String) : InCallException("media failed: $reason")
}

/**
 * The brokered, tenant-scoped session returned by GET /api/session. Credentials are ephemeral and
 * held only for the lifetime of the session (contract §2).
 */
data class Session(
    val tenant: String,
    val user: String,
    val userType: UserType,
    val features: Features,
    val peers: List<Contact>,
    val transferTargets: List<Contact>,
    val directory: List<Contact>,
    val wss: String,
    val realm: String,
    val sipUser: String,
    val authUser: String,
    val sipPassword: String,
    val stun: String?,
    val turn: String?,
    val turnUser: String?,
    val turnPassword: String?,
)
