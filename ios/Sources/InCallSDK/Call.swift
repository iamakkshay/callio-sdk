import Foundation

/// A single call. Methods delegate to the transport; state changes arrive back through the client's
/// delegate (contract §3). Create one via `InCallClient.dial(_:)` or receive it in
/// `client(_:didReceiveIncomingCall:)`.
@MainActor
public final class Call {
    public let id: String
    public let peer: Contact
    public let direction: CallDirection

    public private(set) var state: CallState
    public private(set) var quality: CallQuality?
    public private(set) var isMuted = false
    public private(set) var isOnHold = false

    private let startedAt: Date
    private weak var transport: (any SIPTransport)?

    init(id: String, peer: Contact, direction: CallDirection, state: CallState, transport: any SIPTransport) {
        self.id = id; self.peer = peer; self.direction = direction
        self.state = state; self.transport = transport; self.startedAt = Date()
    }

    /// Seconds since the call connected (0 before connect).
    public var duration: TimeInterval { startedAt.distance(to: Date()) }

    public func answer() async throws { try await transport?.answer() }
    public func hangup() async { await transport?.hangup() }
    public func decline() async { await transport?.decline() }
    public func cancel() async { await transport?.cancel() }

    public func setMuted(_ muted: Bool) async { isMuted = muted; await transport?.setMuted(muted) }
    public func setHold(_ held: Bool) async { isOnHold = held; await transport?.setHold(held) }
    public func setAudioRoute(_ route: AudioRoute) async { await transport?.setAudioRoute(route) }
    public func sendDTMF(_ tone: String) async { await transport?.sendDTMF(tone) }
    public func transfer(to contact: Contact) async throws { try await transport?.transfer(toSipUser: contact.sipUser) }

    // Updated by InCallClient from transport callbacks.
    func apply(state: CallState) { self.state = state }
    func apply(quality: CallQuality) { self.quality = quality }
}
