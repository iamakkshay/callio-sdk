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
    private var answering = false

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
        c.onBye = { [weak self] _ in
            self?.closeMedia()
            let id = self?.currentCallId ?? ""
            self?.onMain { self?.events?.transport(callDidChange: .ended(.ended), callId: id) }
        }
        c.onRemoteHold = { [weak self] held in
            let id = self?.currentCallId ?? ""
            self?.onMain { self?.events?.transport(callDidChange: held ? .onHold : .connected, callId: id) }
        }
        #if canImport(WebRTC)
        c.onReOffer = { [weak self] offer in
            guard let m = self?.media else { throw InCallError.mediaFailed("no call") }
            return try await m.reAnswer(offer)   // hold/resume answered from the live connection
        }
        #endif
        c.onCancel = { [weak self] callId in
            self?.pendingOffer = nil
            self?.onMain { self?.events?.transport(callDidChange: .ended(.missed), callId: callId) }
        }
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
        case "conf":   // an invitation into a 3-way call (same JSON the web client sends)
            if let room = obj["room"] as? String, room.range(of: "^cf-[0-9a-f]{12}$", options: .regularExpression) != nil {
                let with = (obj["with"] as? [String]) ?? []
                let move = (obj["move"] as? Bool) ?? false
                onMain { self.events?.transport(conferenceInviteFrom: fromSip, room: room, move: move, with: with) }
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
        let id = "call-" + UUID().uuidString.prefix(8).description
        currentCallId = id
        // Return straight away so the app can show the call; ringing, answer or refusal arrive as events.
        Task { [weak self] in
            do {
                let answerSdp = try await c.invite(toSip: sipUser, sdpOffer: offer) { status in
                    if (180...183).contains(status) { self?.onMain { self?.events?.transport(callDidChange: .ringing, callId: id) } }
                }
                try await m.setAnswer(answerSdp)
                self?.onMain { self?.events?.transport(callDidChange: .connected, callId: id) }
            } catch {
                // Answered, but our media couldn't start: hang up, or the other side stays in the call.
                if !(error is SipWsClient.InviteFailed) {
                    await c.bye()
                    self?.onMain { self?.events?.transport(didFail: error as? InCallError ?? .mediaFailed("\(error)")) }
                }
                m.close(); if self?.media === m { self?.media = nil }
                let reason: CallEndReason
                switch (error as? SipWsClient.InviteFailed)?.status {
                case 486, 600: reason = .busy
                case 603: reason = .declined
                case 487: reason = .ended                     // we cancelled it
                case 408, 480: reason = .noAnswer
                default: reason = .unreachable
                }
                self?.onMain { self?.events?.transport(callDidChange: .ended(reason), callId: id) }
            }
        }
        return id
    }

    func answer() async throws {
        if answering { return }   // answering takes a moment; ignore a second tap
        answering = true
        defer { answering = false }
        guard let c = client, let s = session, let offer = pendingOffer else { throw InCallError.notRegistered }
        let m = WebRTCMedia(session: s, forceRelay: forceRelay); media = m
        m.onQuality = { [weak self] q in self?.onMain { self?.events?.transport(qualityDidUpdate: q, callId: self?.currentCallId ?? "") } }
        let answerSdp: String
        do { answerSdp = try await m.acceptOffer(offer) }   // fix #1: strip + re-add candidates
        catch { m.close(); media = nil; await decline(); throw error }   // can't start media: refuse rather than leave it ringing
        c.answerIncoming(sdp: answerSdp)
        pendingOffer = nil
        onMain { self.events?.transport(callDidChange: .connected, callId: self.currentCallId ?? "") }
    }

    func setMuted(_ muted: Bool) async { media?.setMuted(muted) }
    /// Hold: tell the other side (re-INVITE written by the WebRTC connection, a=sendonly) and stop sending our audio.
    func setHold(_ held: Bool) async {
        guard let m = media, let c = client else { return }
        m.setHold(held)
        do {
            let offer = try await m.reOffer(held: held)
            guard let answer = await c.reInvite(sdp: offer) else { throw InCallError.network("refused") }
            try await m.setAnswer(answer)
        } catch {
            onMain { self.events?.transport(didFail: .network(held ? "couldn't put the call on hold" : "couldn't resume the call")) }
        }
    }
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
    func decline() async {
        client?.declineIncoming(); pendingOffer = nil
        guard let id = currentCallId else { return }
        onMain { self.events?.transport(callDidChange: .ended(.declined), callId: id) }
    }
    func cancel() async { client?.cancelInvite() }   // the INVITE ends with 487; dial()'s task reports the end
    /// End whatever call there is: decline one that's ringing here, cancel one we're still placing, or BYE a live one.
    func hangup() async {
        if pendingOffer != nil { await decline(); return }
        if let c = client, c.hasOutgoingInvite { c.cancelInvite(); return }
        await client?.bye(); closeMedia()
        guard let id = currentCallId else { return }
        onMain { self.events?.transport(callDidChange: .ended(.ended), callId: id) }
    }
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
