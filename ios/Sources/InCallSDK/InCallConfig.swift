import Foundation

/// SDK configuration. The host app supplies the platform base URL and a `tokenProvider` that returns
/// a short-lived tenant JWT. The SDK never logs users in and stores no long-lived secret (FR-SDK-04):
/// the tenant's own backend authenticates the user and mints the token; the SDK calls `tokenProvider`
/// on start and again whenever the token has expired.
public struct InCallConfig: Sendable {
    public let baseURL: URL
    public let tokenProvider: @Sendable () async throws -> String

    /// Register against TURN relay only (diagnostics / restrictive networks). Mirrors the reference
    /// engine's `relayOnly`.
    public var forceRelay: Bool

    /// NFR-13: close the signalling connection when the app goes to the background (no call in progress) and
    /// reconnect when it comes back. Incoming calls then arrive by VoIP push (InCallCallKit). On by default.
    public var disconnectInBackground: Bool

    public init(
        baseURL: URL,
        forceRelay: Bool = false,
        disconnectInBackground: Bool = true,
        tokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.baseURL = baseURL
        self.forceRelay = forceRelay
        self.disconnectInBackground = disconnectInBackground
        self.tokenProvider = tokenProvider
    }
}

/// The brokered, tenant-scoped session returned by GET /api/session. Credentials are ephemeral and
/// held only for the lifetime of the session (contract §2).
public struct Session: Codable, Sendable {
    public let tenant: String
    public let user: String
    public let userType: UserType
    public let features: Features
    public let peers: [Contact]
    public let transferTargets: [Contact]
    public let directory: [Contact]

    public let wss: String
    public let realm: String
    public let sipUser: String
    public let authUser: String
    public let sipPassword: String

    public let stun: String?
    public let turn: String?
    public let turnUser: String?
    public let turnPassword: String?
}
