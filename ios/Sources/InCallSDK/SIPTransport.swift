import Foundation

/// The media/signalling transport the client drives. The default implementation is a **stub**: the
/// real one is a port of the reference web engine (public/engine/sip.js) onto a native SIP-over-WSS +
/// WebRTC stack, and must carry over its five recovered media fixes:
///   1. answerer SDP candidate strip/re-add
///   2. relay-wait ICE release (no trickle over SIP)
///   3. TURN transport expansion (UDP/TCP/TLS)
///   4. single-contact registrar binding
///   5. register lifecycle + wake handling
///
/// Everything above this protocol (identity, token refresh, events→CDR, history, push registration,
/// the public API) is already implemented; only this needs native WebRTC/SIP work.
protocol SIPTransport: AnyObject {
    var events: SIPTransportEvents? { get set }

    func register(session: Session, forceRelay: Bool) async throws
    func unregister() async

    func dial(to sipUser: String) async throws -> String          // returns a callId
    func answer() async throws
    func decline() async
    func cancel() async
    func hangup() async

    func setMuted(_ muted: Bool) async
    func setHold(_ held: Bool) async
    func setAudioRoute(_ route: AudioRoute) async
    func sendDTMF(_ tone: String) async
    func transfer(toSipUser: String) async throws

    func sendMessage(to sipUser: String, text: String?, location: SharedLocation?) async throws -> String
    func setTyping(_ typing: Bool, to sipUser: String) async
}

/// Callbacks the transport raises; the client translates these into delegate calls.
protocol SIPTransportEvents: AnyObject {
    func transport(registrationDidChange state: RegistrationState)
    func transport(incomingCallFrom sipUser: String, callId: String)
    func transport(callDidChange state: CallState, callId: String)
    func transport(qualityDidUpdate quality: CallQuality, callId: String)
    func transport(messageFrom sipUser: String, text: String?, location: SharedLocation?, messageId: String)
    func transport(messageStatusDidChange messageId: String, status: MessageStatus)
    func transport(didFail error: InCallError)
}

/// Placeholder transport. It drives the client's control flow so the public API is exercisable in
/// tests, but performs no real media. Replace with the native WebRTC/SIP implementation.
final class StubSIPTransport: SIPTransport {
    weak var events: SIPTransportEvents?
    private let notImplemented = InCallError.mediaFailed("SIP/WebRTC transport not implemented — port public/engine/sip.js")

    func register(session: Session, forceRelay: Bool) async throws {
        // A real transport opens the WSS, REGISTERs with digest auth, then reports .registered.
        events?.transport(registrationDidChange: .connecting)
        throw notImplemented
    }
    func unregister() async { events?.transport(registrationDidChange: .offline) }

    func dial(to sipUser: String) async throws -> String { throw notImplemented }
    func answer() async throws { throw notImplemented }
    func decline() async {}
    func cancel() async {}
    func hangup() async {}

    func setMuted(_ muted: Bool) async {}
    func setHold(_ held: Bool) async {}
    func setAudioRoute(_ route: AudioRoute) async {}
    func sendDTMF(_ tone: String) async {}
    func transfer(toSipUser: String) async throws { throw notImplemented }

    func sendMessage(to sipUser: String, text: String?, location: SharedLocation?) async throws -> String { throw notImplemented }
    func setTyping(_ typing: Bool, to sipUser: String) async {}
}
