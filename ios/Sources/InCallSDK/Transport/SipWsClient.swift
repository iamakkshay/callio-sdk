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
        let routes: [String]      // Record-Route values, topmost first
    }
    private var dialog: Dialog?

    /// Inbound requests from the peer. Set before `connect()`.
    var onChatMessage: ((_ fromSip: String, _ body: String) -> Void)?
    var onIncomingInvite: ((_ fromSip: String, _ sdpOffer: String, _ callId: String) -> Void)?
    var onBye: ((_ callId: String) -> Void)?

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
        let n = nextCseq()
        let target = "sip:\(toSip)@\(cfg.realm)"
        var headers = baseHeaders(method: "MESSAGE", to: target, from: "sip:\(cfg.sipUser)@\(cfg.realm)", cseqNum: n)
        headers.append(("Content-Type", contentType))
        let resp = try await request(cseqNum: n, method: "MESSAGE", requestURI: target, headers: headers, body: body)
        guard resp.statusCode == 200 else { throw InCallError.network("MESSAGE failed (\(resp.statusCode ?? 0))") }
        return callId
    }

    // MARK: - INVITE / BYE (signalling; media SDP supplied by the caller's RTCPeerConnection)

    /// Place a call: send INVITE with the caller's gathered SDP offer (fix #2: candidates already in the
    /// SDP — no trickle), authenticate if challenged, and return the 200's answer SDP.
    func invite(toSip: String, sdpOffer: String) async throws -> String {
        let target = "sip:\(toSip)@\(cfg.realm)"
        func send(auth: String?) async throws -> SipMessage {
            let n = nextCseq()
            var headers = baseHeaders(method: "INVITE", to: target, from: "sip:\(cfg.sipUser)@\(cfg.realm)", cseqNum: n)
            headers.append(("Contact", "<sip:\(cfg.sipUser)@\(contactHost);transport=ws>"))
            headers.append(("Content-Type", "application/sdp"))
            if let auth { headers.append(("Proxy-Authorization", auth)) }
            return try await request(cseqNum: n, method: "INVITE", requestURI: target, headers: headers, body: sdpOffer)
        }
        var resp = try await send(auth: nil)
        if resp.statusCode == 407, let ch = resp.header("Proxy-Authenticate").flatMap(DigestAuth.parseChallenge) {
            let auth = DigestAuth.authorization(username: cfg.authUser, password: cfg.password,
                                                method: "INVITE", uri: target, challenge: ch)
            resp = try await send(auth: auth)
        }
        guard resp.statusCode == 200 else { throw InCallError.network("INVITE failed (\(resp.statusCode ?? 0))") }
        // Establish the dialog and ACK the 2xx (a separate transaction to the remote target — RFC 3261
        // §13.2.2.4). Without this the callee retransmits the 200 and tears the call down.
        let localAor = "sip:\(cfg.sipUser)@\(cfg.realm)"
        dialog = Dialog(localAor: localAor,
                        remoteAor: target,
                        remoteTarget: uriOf(resp.header("Contact")) ?? target,
                        remoteTag: tagOf(resp.header("To")),
                        routes: resp.headers.filter { $0.name.caseInsensitiveCompare("Record-Route") == .orderedSame }.map { $0.value })
        if let d = dialog { sendInDialog(method: "ACK", dialog: d, cseqNum: cseqNumber(resp) ?? nextCseq()) }
        return resp.body   // the answer SDP, for the peer connection's setRemoteDescription
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
        headers.append(("Call-ID", callId))
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

    /// Answer the pending inbound INVITE with 200 OK + the WebRTC answer SDP (echoes the dialog headers,
    /// adds our To-tag). The caller's ACK then lands as a request we ignore.
    func answerIncoming(sdp: String) {
        guard let inv = incomingInvite, let w = task else { return }
        var to = inv.header("To") ?? ""
        if !to.contains(";tag=") { to += ";tag=\(fromTag)" }
        let headers: [(String, String)] = [
            ("Via", inv.header("Via") ?? ""),
            ("From", inv.header("From") ?? ""),
            ("To", to),
            ("Call-ID", inv.header("Call-ID") ?? callId),
            ("CSeq", inv.header("CSeq") ?? "1 INVITE"),
            ("Contact", "<sip:\(cfg.sipUser)@\(contactHost);transport=ws>"),
            ("Content-Type", "application/sdp"),
        ]
        w.send(.string(SipMessage.buildResponse(status: 200, reason: "OK", headers: headers, body: sdp))) { _ in }
        // Record the dialog from the inbound INVITE so this (answering) side can send BYE/REFER too.
        dialog = Dialog(localAor: "sip:\(cfg.sipUser)@\(cfg.realm)",
                        remoteAor: uriOf(inv.header("From")) ?? "sip:unknown@\(cfg.realm)",
                        remoteTarget: uriOf(inv.header("Contact")) ?? (uriOf(inv.header("From")) ?? ""),
                        remoteTag: tagOf(inv.header("From")),
                        routes: inv.headers.filter { $0.name.caseInsensitiveCompare("Record-Route") == .orderedSame }.map { $0.value })
    }

    /// Reject the pending inbound INVITE (decline = 603, busy = 486).
    func declineIncoming(status: Int = 603, reason: String = "Decline") {
        guard let inv = incomingInvite, let w = task else { return }
        let headers: [(String, String)] = [
            ("Via", inv.header("Via") ?? ""), ("From", inv.header("From") ?? ""),
            ("To", (inv.header("To") ?? "") + ";tag=\(fromTag)"),
            ("Call-ID", inv.header("Call-ID") ?? callId), ("CSeq", inv.header("CSeq") ?? "1 INVITE"),
        ]
        w.send(.string(SipMessage.buildResponse(status: status, reason: reason, headers: headers))) { _ in }
        incomingInvite = nil
    }

    private func handle(_ m: SipMessage) {
        if let code = m.statusCode {                 // a response to one of our requests
            guard code >= 200 else { return }        // ignore provisional 1xx
            if let n = cseqNumber(m) { takePending(n)?.resume(returning: m) }
            return
        }
        switch m.method {                            // an inbound request from the peer
        case "MESSAGE": onChatMessage?(aorUser(m.header("From")), m.body)
        case "INVITE":  incomingInvite = m; onIncomingInvite?(aorUser(m.header("From")), m.body, m.header("Call-ID") ?? callId)
        case "BYE":     dialog = nil; onBye?(m.header("Call-ID") ?? callId)
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

    private func baseHeaders(method: String, to: String, from: String, cseqNum: Int) -> [(String, String)] {
        [("Via", "SIP/2.0/WS \(contactHost);branch=z9hG4bK\(randToken())"),
         ("Max-Forwards", "70"),
         ("From", "<\(from)>;tag=\(fromTag)"),
         ("To", "<\(to)>"),
         ("Call-ID", callId),
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
