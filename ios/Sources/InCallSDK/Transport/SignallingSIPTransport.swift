import Foundation

/// The default transport. **Registration and chat work without WebRTC**; **calls need the WebRTC
/// framework** (build with `INCALL_WEBRTC=1` — see Package.swift). When it's present, `dial`/`answer`
/// negotiate media via `WebRTCMedia` (RTCPeerConnection + the five SDP/ICE fixes) and the SIP dialog is
/// completed with ACK/BYE/REFER over `SipWsClient`; when it's absent, `dial`/`answer` throw `noMedia`
/// while register/chat/location still work. The remaining on-device work is a run on a physical handset
/// with the CallKit/ConnectionService audio session.
final class SignallingSIPTransport: SIPTransport {
    weak var events: SIPTransportEvents?

    private var client: SipWsClient?
    private var realm = ""
    private var session: Session?
    private var pendingOffer: String?       // the inbound INVITE's offer SDP, awaiting answer()
    private var currentCallId: String?
    #if canImport(WebRTC)
    private var media: WebRTCMedia?
    #endif
    private let noMedia = InCallError.mediaFailed("Add a WebRTC.xcframework to enable calls (see WebRTCMedia.swift)")

    private func onMain(_ block: @escaping () -> Void) { Task { @MainActor in block() } }

    private var forceRelay = false

    func register(session: Session, forceRelay: Bool) async throws {
        onMain { self.events?.transport(registrationDidChange: .connecting) }
        realm = session.realm
        self.session = session
        self.forceRelay = forceRelay
        let c = SipWsClient(config: .init(wss: session.wss, realm: session.realm, sipUser: session.sipUser,
                                          authUser: session.authUser, password: session.sipPassword))
        c.onChatMessage = { [weak self] fromSip, body in self?.handleInbound(fromSip: fromSip, body: body) }
        c.onIncomingInvite = { [weak self] fromSip, offer, callId in
            self?.pendingOffer = offer; self?.currentCallId = callId
            self?.onMain { self?.events?.transport(incomingCallFrom: fromSip, callId: callId) }
        }
        c.onBye = { [weak self] callId in self?.onMain { self?.events?.transport(callDidChange: .ended(.ended), callId: callId) } }
        client = c
        try c.connect()
        try await c.register()
        onMain { self.events?.transport(registrationDidChange: .registered) }
    }

    func unregister() async { await client?.unregister(); client?.close(); client = nil }

    // Chat + location over SIP MESSAGE (the same JSON protocol the reference web client uses).
    func sendMessage(to sipUser: String, text: String?, location: SharedLocation?) async throws -> String {
        guard let c = client else { throw InCallError.notRegistered }
        let id = UUID().uuidString.prefix(10).description
        var payload: [String: Any] = ["key": "me:" + id]
        if let location {
            payload["t"] = "loc"
            payload["loc"] = ["lat": location.lat, "lng": location.lng, "label": location.label] as [String: Any]
        } else {
            payload["t"] = "text"
            payload["text"] = text ?? ""
        }
        let body = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"
        _ = try await c.message(toSip: sipUser, contentType: "application/json", body: body)
        return "me:" + id
    }

    func setTyping(_ typing: Bool, to sipUser: String) async {
        let body = #"{"t":"typing","on":\#(typing)}"#
        _ = try? await client?.message(toSip: sipUser, contentType: "application/json", body: body)
    }

    private func handleInbound(fromSip: String, body: String) {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let key = obj["key"] as? String ?? UUID().uuidString
        switch obj["t"] as? String {
        case "text":
            let text = obj["text"] as? String
            onMain { self.events?.transport(messageFrom: fromSip, text: text, location: nil, messageId: key) }
        case "loc":
            if let l = obj["loc"] as? [String: Any], let lat = l["lat"] as? Double, let lng = l["lng"] as? Double {
                let loc = SharedLocation(lat: lat, lng: lng, label: l["label"] as? String ?? "Shared location")
                onMain { self.events?.transport(messageFrom: fromSip, text: nil, location: loc, messageId: key) }
            }
        default: break   // typing / read receipts: wire through as needed
        }
    }

    // MARK: - Call control
    // Fully wired when a WebRTC framework is present; throws `noMedia` otherwise.

#if canImport(WebRTC)
    func dial(to sipUser: String) async throws -> String {
        guard let c = client, let s = session else { throw InCallError.notRegistered }
        let m = WebRTCMedia(session: s, forceRelay: forceRelay); media = m
        m.onQuality = { [weak self] q in self?.onMain { self?.events?.transport(qualityDidUpdate: q, callId: self?.currentCallId ?? "") } }
        let offer = try await m.createOffer()                 // fix #2: candidate-laden offer
        let answerSdp = try await c.invite(toSip: sipUser, sdpOffer: offer)
        try await m.setAnswer(answerSdp)
        let id = "call-" + UUID().uuidString.prefix(8).description
        currentCallId = id
        onMain { self.events?.transport(callDidChange: .connected, callId: id) }
        return id
    }

    func answer() async throws {
        guard let c = client, let s = session, let offer = pendingOffer else { throw InCallError.notRegistered }
        let m = WebRTCMedia(session: s, forceRelay: forceRelay); media = m
        m.onQuality = { [weak self] q in self?.onMain { self?.events?.transport(qualityDidUpdate: q, callId: self?.currentCallId ?? "") } }
        let answerSdp = try await m.acceptOffer(offer)        // fix #1: strip + re-add candidates
        c.answerIncoming(sdp: answerSdp)
        pendingOffer = nil
        onMain { self.events?.transport(callDidChange: .connected, callId: self.currentCallId ?? "") }
    }

    func setMuted(_ muted: Bool) async { media?.setMuted(muted) }
    func setHold(_ held: Bool) async { media?.setHold(held) }
    func sendDTMF(_ tone: String) async {}                   // TODO: RTCRtpSender.insertDtmf
    private func closeMedia() { media?.close(); media = nil }
#else
    func dial(to sipUser: String) async throws -> String { throw noMedia }
    func answer() async throws { throw noMedia }
    func setMuted(_ muted: Bool) async {}
    func setHold(_ held: Bool) async {}
    func sendDTMF(_ tone: String) async {}
    private func closeMedia() {}
#endif

    // Signalling-only call control — works with or without the WebRTC framework (no media involved).
    func decline() async { client?.declineIncoming(); pendingOffer = nil }
    func cancel() async { await client?.bye(); closeMedia() }           // outgoing teardown (dialog or none)
    func hangup() async { await client?.bye(); closeMedia() }           // in-dialog BYE + release media
    func transfer(toSipUser: String) async throws {                     // blind transfer via in-dialog REFER
        guard let c = client else { throw InCallError.notRegistered }
        try await c.refer(toSip: toSipUser)
    }
    func setAudioRoute(_ route: AudioRoute) async {
        #if os(iOS)
        await MainActor.run { do { try AudioRouter.shared.set(route) } catch { self.events?.transport(didFail: error as? InCallError ?? .mediaFailed("\(error)")) } }
        #endif
    }
}
