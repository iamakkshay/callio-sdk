// Public value types shared across the SDK. These mirror the platform's /api/session shape and the
// reference web engine's state surface (public/engine/sip.js), so native and web behave identically.
import Foundation

/// Where the client stands with the signalling server.
public enum RegistrationState: String, Sendable {
    case connecting, registered, offline
}

/// Who the user is to the platform (carried in the JWT, enforced server-side) — FR-SDK-13.
public enum UserType: String, Codable, Sendable {
    case customer, agent
}

/// Per-tenant feature flags; the SDK and UI honour these (FR-MT / FR-ADM).
public struct Features: Codable, Sendable, Equatable {
    public var calling: Bool
    public var chat: Bool
    public var location: Bool
    public var recording: Bool

    public init(calling: Bool = true, chat: Bool = true, location: Bool = true, recording: Bool = false) {
        self.calling = calling; self.chat = chat; self.location = location; self.recording = recording
    }
}

/// A person the user can call or message.
public struct Contact: Codable, Sendable, Equatable, Identifiable {
    public let name: String          // stable username / tenant user id
    public let sipUser: String       // SIP extension
    public let displayName: String
    public let userType: UserType
    public var id: String { name }
}

public enum CallDirection: String, Codable, Sendable { case incoming, outgoing }

/// Why a call ended — mirrors the reference engine's end reasons (FR-CALL-05).
public enum CallEndReason: String, Sendable {
    case ended, declined, missed, noAnswer = "no-answer", busy, unreachable
}

/// Call lifecycle states (FR-CALL-05).
public enum CallState: Sendable, Equatable {
    case initiating, ringing, connected, onHold, reconnecting
    case ended(CallEndReason)
}

/// Live call quality (FR-CALL-11). `mos` is optional until MOS scoring lands.
public struct CallQuality: Sendable, Equatable {
    public let rttMs: Int?
    public let jitterMs: Int?
    public let lossPct: Double?
    public let mos: Double?

    public init(rttMs: Int? = nil, jitterMs: Int? = nil, lossPct: Double? = nil, mos: Double? = nil) {
        self.rttMs = rttMs; self.jitterMs = jitterMs; self.lossPct = lossPct; self.mos = mos
    }
}

/// Where call audio is routed (FR-CALL-04). Mapped to AVAudioSession / CallKit by the transport.
public enum AudioRoute: String, Sendable { case speaker, earpiece, bluetooth }

public enum MessageSender: String, Sendable { case me, peer }
public enum MessageStatus: String, Sendable { case sending, sent, delivered, read, failed }

public struct SharedLocation: Codable, Sendable, Equatable {
    public let lat: Double
    public let lng: Double
    public let label: String
}

public struct Message: Sendable, Equatable, Identifiable {
    public let id: String
    public let from: MessageSender
    public let text: String?
    public let location: SharedLocation?
    public var status: MessageStatus
}

/// One row of per-user call history (FR-CALL-08), from GET /api/history.
public struct HistoryEntry: Codable, Sendable, Identifiable {
    public let callId: String
    public let peer: String
    public let peerDisplayName: String
    public let peerSipUser: String?
    public let direction: CallDirection
    public let outcome: String
    public let durationSec: Int
    public let at: String            // ISO-8601
    public var id: String { callId }
}

/// Errors surfaced to the integrator — stable `code` for programmatic handling (contract §7).
public enum InCallError: Error, Sendable, Equatable {
    case notRegistered
    case micPermission
    case peerUnreachable
    case busy
    case tokenExpired
    case featureDisabled(String)
    case network(String)
    case mediaFailed(String)
}
