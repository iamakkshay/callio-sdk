import Foundation

/// Push registration (FR-SDK-06 / FR-CALL-03). The host app obtains an APNs **VoIP** token via PushKit
/// and hands it here; the SDK registers it with the platform so a backgrounded/killed app can be woken
/// to ring. When the platform delivers the push, the app reports the call to **CallKit** immediately
/// (an OS requirement) and then the SDK pulls the session and connects media.
///
/// PushKit/CallKit wiring lives in the host app (it needs the app's entitlements and UIApplication
/// lifecycle); this service only owns the platform registration half.
public actor PushService {
    private let api: PlatformAPI
    private let deviceId: String

    init(api: PlatformAPI, deviceId: String) {
        self.api = api
        self.deviceId = deviceId
    }

    /// Call from `pushRegistry(_:didUpdate:for:)` with the VoIP token's hex string.
    public func register(voipToken: String) async throws {
        try await api.registerPush(deviceId: deviceId, token: voipToken)
    }

    public func unregister() async throws {
        try await api.unregisterPush(deviceId: deviceId)
    }

    /// Shape of the wake-up payload the platform sends (see repos/push.js `notifyIncomingCall`):
    /// `{ type: "incoming_call", callId, tenant, to, from: { displayName, userType }, ttlSec }`.
    public struct IncomingCallPush: Sendable {
        public let callId: String
        public let fromDisplayName: String
        public let tenant: String
    }

    /// Parse the APNs payload dictionary into a typed push. Returns nil if it isn't an incoming call.
    public nonisolated static func parse(_ userInfo: [AnyHashable: Any]) -> IncomingCallPush? {
        guard let n = userInfo["notification"] as? [String: Any] ?? userInfo as? [String: Any],
              (n["type"] as? String) == "incoming_call",
              let callId = n["callId"] as? String,
              let tenant = n["tenant"] as? String else { return nil }
        let from = n["from"] as? [String: Any]
        let name = (from?["displayName"] as? String) ?? "Caller"
        return IncomingCallPush(callId: callId, fromDisplayName: name, tenant: tenant)
    }
}
