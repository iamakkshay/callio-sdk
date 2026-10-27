import Foundation

private func randToken() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased().description
}

/// SIP-over-WebSocket signalling client (RFC 7118). This is the **signalling half** of the native
/// transport and is complete on its own: it opens the `wss`, REGISTERs with digest auth, sends/receives
/// SIP MESSAGE (chat), and carries INVITE/ACK/BYE. It performs **no media** — the WebRTC
/// `RTCPeerConnection` and the five SDP/ICE fixes (see SIPTransport.swift / WEBRTC_TRANSPORT_PORT.md)
/// are supplied by the caller: `invite(sdpOffer:)` takes an offer and returns the answer SDP to feed
/// back into the peer connection. Registration and chat need no WebRTC and work as-is.
///
/// A plain class guarded by a lock (URLSessionWebSocketTask is thread-safe) rather than an actor, so the
/// request/response continuation bookkeeping stays simple.
final class SipWsClient: @unchecked Sendable {
    struct Config { let wss: String; let realm: String; let sipUser: String; let authUser: String; let password: String }

    private let cfg: Config
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var cseq = 0
    private var pending: [Int: CheckedContinuation<SipMessage, Error>] = [:]
    private let callId = randToken() + "@incall.invalid"
    private let fromTag = randToken()
    private let contactHost = randToken() + ".invalid"
    private var incomingInvite: SipMessage?   // the last inbound INVITE, to answer/decline

    /// Established INVITE dialog, captured from the 2xx (caller) or the inbound INVITE (callee), so we can
    /// ACK the 2xx and later send in-dialog BYE/REFER to the remote target. The lab Kamailio does not
    /// Record-Route, so `routes` is normally empty; it's carried through for a proxy that does.
    private struct Dialog {
        let localAor: String      // our AOR URI (From)
        let remoteAor: String     // peer AOR URI (To)
        let remoteTarget: String  // peer Contact (the request-URI for in-dialog requests)
        let remoteTag: String
        let routes: [String]      // the route set, in the order Route headers are sent
        let callId: String
    }
    private var dialog: Dialog?

    /// The INVITE we sent and haven't had a final answer to, so it can be CANCELled.
    private struct OutgoingInvite { let target: String; let callId: String; let cseq: Int; let via: String; let from: String; let to: String }
    private var outgoing: OutgoingInvite?
    private var onOutgoingProgress: ((Int) -> Void)?

    /// The callee (or the proxy) turned the call down with this final status: 486 busy, 603 declined, 487 cancelled...
    struct InviteFailed: Error { let status: Int }

    /// Inbound requests from the peer. Set before `connect()`.
    var onChatMessage: ((_ fromSip: String, _ body: String) -> Void)?
    var onIncomingInvite: ((_ fromSip: String, _ sdpOffer: String, _ callId: String) -> Void)?
    var onBye: ((_ callId: String) -> Void)?
    /// The caller gave up (or the proxy timed the call out) before we answered.
    var onCancel: ((_ callId: String) -> Void)?

    init(config: Config) { self.cfg = config }

    func connect() throws {
        guard let url = URL(string: cfg.wss) else { throw InCallError.network("bad wss URL") }
        var req = URLRequest(url: url)
        req.setValue("sip", forHTTPHeaderField: "Sec-WebSocket-Protocol")   // RFC 7118 subprotocol
        let t = URLSession(configuration: .ephemeral).webSocketTask(with: req)
        task = t
        t.resume()
        Task { await receiveLoop(t) }
    }

    func close() { task?.cancel(with: .goingAway, reason: nil); task = nil }

    // MARK: - REGISTER (with digest), FR-SDK-04 / fix #4

    func register(expires: Int = 120) async throws {
        let aor = "sip:\(cfg.sipUser)@\(cfg.realm)"
        func send(auth: String?) async throws -> SipMessage {
            let n = nextCseq()
            var headers = baseHeaders(method: "REGISTER", to: aor, from: aor, cseqNum: n)
            headers.append(("Contact", "<sip:\(cfg.sipUser)@\(contactHost);transport=ws>"))
            headers.append(("Expires", String(expires)))
            if let auth { headers.append(("Authorization", auth)) }
            return try await request(cseqNum: n, method: "REGISTER", requestURI: "sip:\(cfg.realm)", headers: headers)
        }
        var resp = try await send(auth: nil)
        if resp.statusCode == 401, let ch = resp.header("WWW-Authenticate").flatMap(DigestAuth.parseChallenge) {
            let auth = DigestAuth.authorization(username: cfg.authUser, password: cfg.password,
                                                method: "REGISTER", uri: "sip:\(cfg.realm)", challenge: ch)
            resp = try await send(auth: auth)
        }
        guard resp.statusCode == 200 else { throw InCallError.network("REGISTER failed (\(resp.statusCode ?? 0))") }
    }

    func unregister() async { _ = try? await register(expires: 0) }

    // MARK: - MESSAGE (chat), FR-CHAT-01

    @discardableResult
    func message(toSip: String, contentType: String, body: String) async throws -> String {
        let target = "sip:\(toSip)@\(cfg.realm)"
        let cid = randToken() + "@incall.invalid"
        func send(auth: String?) async throws -> SipMessage {
            let n = nextCseq()
            var headers = baseHeaders(method: "MESSAGE", to: target, from: "sip:\(cfg.sipUser)@\(cfg.realm)", cseqNum: n, callId: cid)
            headers.append(("Content-Type", contentType))
            if let auth { headers.append(("Proxy-Authorization", auth)) }
            return try await request(cseqNum: n, method: "MESSAGE", requestURI: target, headers: headers, body: body)
        }
        var resp = try await send(auth: nil)
        // The proxy challenges every request from us, like INVITE.
        if resp.statusCode == 407, let ch = resp.header("Proxy-Authenticate").flatMap(DigestAuth.parseChallenge) {
            let auth = DigestAuth.authorization(username: cfg.authUser, password: cfg.password,
                                                method: "MESSAGE", uri: target, challenge: ch)
            resp = try await send(auth: auth)
        }
        guard (resp.statusCode ?? 0) / 100 == 2 else { throw InCallError.network("MESSAGE failed (\(resp.statusCode ?? 0))") }
        return cid
    }

    // MARK: - INVITE / BYE (signalling; media SDP supplied by the caller's RTCPeerConnection)

    /// Place a call: send INVITE with the caller's gathered SDP offer (fix #2: candidates already in the
    /// SDP — no trickle), authenticate if challenged, and return the 200's answer SDP. Each call gets its own
    /// Call-ID. `onProgress` hears provisional replies (180 = ringing). Throws `InviteFailed` when refused.
    func invite(toSip: String, sdpOffer: String, onProgress: @escaping (Int) -> Void = { _ in }) async throws -> String {
        let target = "sip:\(toSip)@\(cfg.realm)"
        let cid = randToken() + "@incall.invalid"
        setOutgoing(nil, progress: onProgress)
        defer { setOutgoing(nil, progress: nil) }
        func send(auth: String?) async throws -> SipMessage {
            let n = nextCseq()
            var headers = baseHeaders(method: "INVITE", to: target, from: "sip:\(cfg.sipUser)@\(cfg.realm)", cseqNum: n, callId: cid)
            headers.append(("Contact", "<sip:\(cfg.sipUser)@\(contactHost);transport=ws>"))
            headers.append(("Content-Type", "application/sdp"))
            if let auth { headers.append(("Proxy-Authorization", auth)) }
            func h(_ name: String) -> String { headers.first { $0.0 == name }?.1 ?? "" }
            setOutgoing(OutgoingInvite(target: target, callId: cid, cseq: n, via: h("Via"), from: h("From"), to: h("To")), progress: onProgress)
            return try await request(cseqNum: n, method: "INVITE", requestURI: target, headers: headers, body: sdpOffer)
        }
        var resp = try await send(auth: nil)
        if resp.statusCode == 407, let ch = resp.header("Proxy-Authenticate").flatMap(DigestAuth.parseChallenge) {
            ackFailure(resp)
            let auth = DigestAuth.authorization(username: cfg.authUser, password: cfg.password,
                                                method: "INVITE", uri: target, challenge: ch)
            resp = try await send(auth: auth)
        }
        let code = resp.statusCode ?? 500
        guard code / 100 == 2 else { ackFailure(resp); throw InviteFailed(status: code) }
        // Establish the dialog and ACK the 2xx (a separate transaction to the remote target — RFC 3261
        // §13.2.2.4). Without this the callee retransmits the 200 and tears the call down.
        let localAor = "sip:\(cfg.sipUser)@\(cfg.realm)"
        let d = Dialog(localAor: localAor,
                       remoteAor: target,
                       remoteTarget: uriOf(resp.header("Contact")) ?? target,
                       remoteTag: tagOf(resp.header("To")),
                       routes: resp.headers.filter { $0.name.caseInsensitiveCompare("Record-Route") == .orderedSame }.map { $0.value }.reversed(),
                       callId: cid)
        dialog = d
        sendInDialog(method: "ACK", dialog: d, cseqNum: cseqNumber(resp) ?? nextCseq())
        return resp.body   // the answer SDP, for the peer connection's setRemoteDescription
    }

    private func setOutgoing(_ o: OutgoingInvite?, progress: ((Int) -> Void)?) {
        lock.lock(); outgoing = o; onOutgoingProgress = progress; lock.unlock()
    }

    var hasOutgoingInvite: Bool { lock.lock(); defer { lock.unlock() }; return outgoing != nil }

    /// Give up on the call we're placing before it's answered. The INVITE then ends with 487.
    func cancelInvite() {
        lock.lock(); let o = outgoing; lock.unlock()
        guard let o, let t = task else { return }
        let raw = SipMessage.buildRequest(method: "CANCEL", requestURI: o.target, headers: [
            ("Via", o.via), ("Max-Forwards", "70"), ("From", o.from), ("To", o.to),
            ("Call-ID", o.callId), ("CSeq", "\(o.cseq) CANCEL"),
        ], body: "")
        t.send(.string(raw)) { _ in }
    }

    /// A non-2xx final reply to our INVITE is ACKed in the same transaction (same Via branch), or the proxy keeps resending it.
    private func ackFailure(_ resp: SipMessage) {
        lock.lock(); let o = outgoing; lock.unlock()
        guard let o, let t = task else { return }
        let raw = SipMessage.buildRequest(method: "ACK", requestURI: o.target, headers: [
            ("Via", o.via), ("Max-Forwards", "70"), ("From", o.from), ("To", resp.header("To") ?? o.to),
            ("Call-ID", o.callId), ("CSeq", "\(o.cseq) ACK"),
        ], body: "")
        t.send(.string(raw)) { _ in }
    }

    /// Send an in-dialog request (ACK/BYE/REFER) to the remote target. ACK for a 2xx reuses the INVITE's
    /// CSeq number; BYE/REFER take a fresh one. Fire-and-forget for ACK; BYE/REFER callers await via the
    /// pending map on `cseqNum`.
    private func sendInDialog(method: String, dialog d: Dialog, cseqNum: Int, extraHeaders: [(String, String)] = []) {
        guard let t = task else { return }
        var headers: [(String, String)] = [
            ("Via", "SIP/2.0/WS \(contactHost);branch=z9hG4bK\(randToken())"),
            ("Max-Forwards", "70"),
        ]
        for r in d.routes { headers.append(("Route", r)) }
        headers.append(("To", "<\(d.remoteAor)>;tag=\(d.remoteTag)"))
        headers.append(("From", "<\(d.localAor)>;tag=\(fromTag)"))
        headers.append(("Call-ID", d.callId))
        headers.append(("CSeq", "\(cseqNum) \(method)"))
        headers.append(contentsOf: extraHeaders)
        let raw = SipMessage.buildRequest(method: method, requestURI: d.remoteTarget, headers: headers, body: "")
        t.send(.string(raw)) { _ in }
    }

    /// Hang up an established call: in-dialog BYE to the remote target, wait for its 200.
    func bye() async {
        guard let d = dialog else { return }
        let n = nextCseq()
        _ = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<SipMessage, Error>) in
            lock.lock(); pending[n] = cont; lock.unlock()
            sendInDialog(method: "BYE", dialog: d, cseqNum: n)
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.takePending(n)?.resume(throwing: InCallError.network("BYE timeout"))
            }
        }
        dialog = nil
    }

    /// Blind transfer (REFER) the established call to another user. In-dialog; proxy routes by alias.
    func refer(toSip: String) async throws {
        guard let d = dialog else { throw InCallError.network("no active call to transfer") }
        let n = nextCseq()
        let resp: SipMessage = try await withCheckedThrowingContinuation { cont in
            lock.lock(); pending[n] = cont; lock.unlock()
            sendInDialog(method: "REFER", dialog: d, cseqNum: n, extraHeaders: [
                ("Refer-To", "<sip:\(toSip)@\(cfg.realm)>"),
                ("Referred-By", "<\(d.localAor)>"),
            ])
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.takePending(n)?.resume(throwing: InCallError.network("REFER timeout"))
            }
        }
        guard (resp.statusCode ?? 0) / 100 == 2 else { throw InCallError.network("REFER rejected (\(resp.statusCode ?? 0))") }
    }

    private func tagOf(_ header: String?) -> String {
        guard let h = header, let r = h.range(of: "tag=") else { return "" }
        return String(h[r.upperBound...].prefix { $0 != ";" && $0 != ">" && $0 != " " && $0 != "\r" && $0 != "\n" })
    }
    private func uriOf(_ header: String?) -> String? {
        guard let h = header else { return nil }
        if let lt = h.range(of: "<"), let gt = h.range(of: ">", range: lt.upperBound..<h.endIndex) {
            return String(h[lt.upperBound..<gt.lowerBound])
        }
        let v = h.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    // MARK: - receive loop

    private func receiveLoop(_ t: URLSessionWebSocketTask) async {
        while true {
            let msg: URLSessionWebSocketTask.Message
            do { msg = try await t.receive() } catch { failAllPending(); return }
            if case let .string(text) = msg { handle(SipMessage.parse(text)) }
        }
    }

    /// Answer the pending inbound INVITE with 200 OK + the WebRTC answer SDP. The caller's ACK then lands
    /// as a request we ignore.
    func answerIncoming(sdp: String) {
        guard let inv = incomingInvite else { return }
        respond(to: inv, status: 200, reason: "OK", sdp: sdp, withDialog: true)
        incomingInvite = nil
        // Record the dialog from the inbound INVITE so this (answering) side can send BYE/REFER too.
        dialog = Dialog(localAor: "sip:\(cfg.sipUser)@\(cfg.realm)",
                        remoteAor: uriOf(inv.header("From")) ?? "sip:unknown@\(cfg.realm)",
                        remoteTarget: uriOf(inv.header("Contact")) ?? (uriOf(inv.header("From")) ?? ""),
                        remoteTag: tagOf(inv.header("From")),
                        routes: inv.headers.filter { $0.name.caseInsensitiveCompare("Record-Route") == .orderedSame }.map { $0.value },
                        callId: inv.header("Call-ID") ?? callId)
    }

    /// Reject the pending inbound INVITE (decline = 603, busy = 486).
    func declineIncoming(status: Int = 603, reason: String = "Decline") {
        guard let inv = incomingInvite else { return }
        respond(to: inv, status: status, reason: reason)
        incomingInvite = nil
    }

    /// Reply to an inbound request. A response must carry every Via of the request, in order (the proxy's
    /// own Via first), or it can't be routed back to the caller; From, Call-ID and CSeq are echoed, and To
    /// gets our tag. `withDialog` adds Contact and Record-Route, for the 1xx/2xx that set up a call.
    private func respond(to req: SipMessage, status: Int, reason: String, sdp: String = "", withDialog: Bool = false) {
        guard let w = task else { return }
        func named(_ n: String) -> [String] { req.headers.filter { $0.name.caseInsensitiveCompare(n) == .orderedSame }.map { $0.value } }
        var headers: [(String, String)] = (named("Via") + named("v")).map { ("Via", $0) }
        if withDialog { headers += named("Record-Route").map { ("Record-Route", $0) } }
        let to = req.header("To") ?? ""
        headers.append(("From", req.header("From") ?? ""))
        headers.append(("To", status == 100 || to.contains(";tag=") ? to : to + ";tag=\(fromTag)"))
        headers.append(("Call-ID", req.header("Call-ID") ?? callId))
        headers.append(("CSeq", req.header("CSeq") ?? "1 \(req.method ?? "")"))
        if withDialog { headers.append(("Contact", "<sip:\(cfg.sipUser)@\(contactHost);transport=ws>")) }
        if !sdp.isEmpty { headers.append(("Content-Type", "application/sdp")) }
        w.send(.string(SipMessage.buildResponse(status: status, reason: reason, headers: headers, body: sdp))) { _ in }
    }

    private func handle(_ m: SipMessage) {
        if let code = m.statusCode {                 // a response to one of our requests
            if m.header("CSeq")?.trimmingCharacters(in: .whitespaces).uppercased().hasSuffix("CANCEL") == true { return }   // shares the INVITE's CSeq number
            if code >= 200 {
                if let n = cseqNumber(m) { takePending(n)?.resume(returning: m) }
            } else if code > 100 {
                lock.lock(); let o = outgoing; let progress = onOutgoingProgress; lock.unlock()
                if let o, cseqNumber(m) == o.cseq, m.header("Call-ID") == o.callId { progress?(code) }
            }
            return
        }
        switch m.method {                            // an inbound request from the peer
        case "MESSAGE":
            respond(to: m, status: 200, reason: "OK")   // without this the sender sees the message fail
            onChatMessage?(aorUser(m.header("From")), m.body)
        case "INVITE":
            let cid = m.header("Call-ID") ?? callId
            if incomingInvite?.header("Call-ID") == cid { return }   // a retransmission of the one ringing
            if incomingInvite != nil { respond(to: m, status: 486, reason: "Busy Here"); return }   // another call is already ringing
            incomingInvite = m
            // Tell the caller we're ringing at once: the proxy gives up on a silent device after a few seconds.
            respond(to: m, status: 100, reason: "Trying")
            respond(to: m, status: 180, reason: "Ringing", withDialog: true)
            onIncomingInvite?(aorUser(m.header("From")), m.body, cid)
        case "CANCEL":
            respond(to: m, status: 200, reason: "OK")
            if let inv = incomingInvite, inv.header("Call-ID") == m.header("Call-ID") {
                respond(to: inv, status: 487, reason: "Request Terminated")
                incomingInvite = nil
                onCancel?(m.header("Call-ID") ?? callId)
            }
        case "BYE":
            respond(to: m, status: 200, reason: "OK")
            dialog = nil
            onBye?(m.header("Call-ID") ?? callId)
        case "OPTIONS":
            respond(to: m, status: 200, reason: "OK")
        default: break
        }
    }

    // MARK: - request/response plumbing (lock-guarded)

    private func nextCseq() -> Int { lock.lock(); defer { lock.unlock() }; cseq += 1; return cseq }
    private func takePending(_ n: Int) -> CheckedContinuation<SipMessage, Error>? {
        lock.lock(); defer { lock.unlock() }; return pending.removeValue(forKey: n)
    }
    private func failAllPending() {
        lock.lock(); let all = pending; pending.removeAll(); lock.unlock()
        for (_, c) in all { c.resume(throwing: InCallError.network("socket closed")) }
    }

    private func request(cseqNum: Int, method: String, requestURI: String,
                         headers: [(String, String)], body: String = "") async throws -> SipMessage {
        guard let t = task else { throw InCallError.notRegistered }
        let raw = SipMessage.buildRequest(method: method, requestURI: requestURI, headers: headers, body: body)
        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); pending[cseqNum] = cont; lock.unlock()
            t.send(.string(raw)) { [weak self] err in
                if let err { self?.takePending(cseqNum)?.resume(throwing: InCallError.network(err.localizedDescription)) }
            }
        }
    }

    private func baseHeaders(method: String, to: String, from: String, cseqNum: Int, callId cid: String? = nil) -> [(String, String)] {
        [("Via", "SIP/2.0/WS \(contactHost);branch=z9hG4bK\(randToken())"),
         ("Max-Forwards", "70"),
         ("From", "<\(from)>;tag=\(fromTag)"),
         ("To", "<\(to)>"),
         ("Call-ID", cid ?? callId),
         ("CSeq", "\(cseqNum) \(method)"),
         ("User-Agent", "InCallSDK-ios/\(InCallSDKVersion.current)")]
    }

    private func cseqNumber(_ m: SipMessage) -> Int? {
        m.header("CSeq").flatMap { Int($0.split(separator: " ").first.map(String.init) ?? "") }
    }

    private func aorUser(_ header: String?) -> String {
        guard let h = header, let lo = h.range(of: "sip:")?.upperBound else { return "" }
        return String(h[lo...].prefix { $0 != "@" && $0 != ">" })
    }
}
