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

    /// DEVELOPMENT ONLY: allow an `http://` baseURL and `ws://` signalling (a local stack or lab server).
    /// Without it `start()` requires `https://` and `wss://`, so tokens and SIP credentials never travel in
    /// clear text. Never set this in a release build.
    public var allowInsecureTransport: Bool

    public init(
        baseURL: URL,
        forceRelay: Bool = false,
        disconnectInBackground: Bool = true,
        allowInsecureTransport: Bool = false,
        tokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.baseURL = baseURL
        self.forceRelay = forceRelay
        self.disconnectInBackground = disconnectInBackground
        self.allowInsecureTransport = allowInsecureTransport
        self.tokenProvider = tokenProvider
    }
}

/// Scheme checks for the platform URL and the session's signalling URL.
enum TransportSecurity {
    /// Throws `InCallError.network` unless `url` uses `secure`, or `insecure` when `allowInsecure` is set.
    static func check(_ url: String, secure: String, insecure: String, allowInsecure: Bool, what: String) throws {
        let parts = url.components(separatedBy: "://")
        let scheme = parts.count > 1 ? parts[0].lowercased() : ""
        let hasHost = parts.count > 1 && !parts[1].isEmpty
        if hasHost && (scheme == secure || (scheme == insecure && allowInsecure)) { return }
        throw InCallError.network(scheme == insecure
            ? "\(what) must use \(secure):// (\(insecure):// is allowed only with allowInsecureTransport, for development)"
            : "\(what) must be a \(secure):// URL")
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

/// The SIP and TURN passwords are left out of `print`, string interpolation, `debugPrint` and `dump`.
extension Session: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "Session(tenant: \(tenant), user: \(user), userType: \(userType), wss: \(wss), realm: \(realm), "
            + "sipUser: \(sipUser), authUser: \(authUser), sipPassword: <redacted>, stun: \(stun ?? "nil"), "
            + "turn: \(turn ?? "nil"), turnUser: \(turnUser ?? "nil"), turnPassword: \(turnPassword == nil ? "nil" : "<redacted>"), "
            + "peers: \(peers.count), transferTargets: \(transferTargets.count), directory: \(directory.count))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: [
            "tenant": tenant, "user": user, "userType": userType, "features": features, "peers": peers,
            "transferTargets": transferTargets, "directory": directory, "wss": wss, "realm": realm,
            "sipUser": sipUser, "authUser": authUser, "sipPassword": "<redacted>", "stun": stun as Any,
            "turn": turn as Any, "turnUser": turnUser as Any, "turnPassword": (turnPassword == nil ? "nil" : "<redacted>") as Any,
        ], displayStyle: .struct)
    }
}
