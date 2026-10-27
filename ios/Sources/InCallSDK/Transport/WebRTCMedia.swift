// WebRTC media engine — the on-device half of the transport. Guarded by `#if canImport(WebRTC)` so the
// SDK compiles (and CI stays green) without the framework; drop in a WebRTC.xcframework (e.g. the
// `stasel/WebRTC` SwiftPM package or a Google libwebrtc build) and it activates with no other changes.
//
// Implements the five recovered media fixes from the reference engine (public/engine/ice.js, sip.js):
//   #1 answerer SDP candidate strip/re-add   #2 relay-wait ICE release (no trickle over SIP)
//   #3 TURN transport expansion               #4 single-contact registrar (in SipWsClient)
//   #5 register lifecycle (app lifecycle + push, in the host app)
#if canImport(WebRTC)
import Foundation
import WebRTC

final class WebRTCMedia: NSObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private let pc: RTCPeerConnection
    private let audioTrack: RTCAudioTrack
    private let relayOnly: Bool
    private let hasTurn: Bool
    private let hasStun: Bool

    // fix #1: candidates stripped from the inbound offer, re-added after our answer is set.
    private var heldRemote: [(line: String, mid: String)] = []
    // fix #2: the gather gate.
    private var gatherCont: CheckedContinuation<Void, Never>?
    private var gatherDone = false

    private var statsTimer: Timer?
    private var prevInbound: (received: UInt64, lost: UInt64)?
    var onQuality: ((CallQuality) -> Void)?

    init(session: Session, forceRelay: Bool) {
        relayOnly = forceRelay
        hasTurn = session.turn != nil
        hasStun = session.stun != nil

        var iceServers: [RTCIceServer] = []
        if let stun = session.stun { iceServers.append(RTCIceServer(urlStrings: [stun])) }
        if let turn = session.turn, let u = session.turnUser, let p = session.turnPassword {
            iceServers.append(RTCIceServer(urlStrings: WebRTCMedia.turnUrls(turn), username: u, credential: p))  // fix #3
        }
        let cfg = RTCConfiguration()
        cfg.iceServers = iceServers
        cfg.iceTransportPolicy = forceRelay ? .relay : .all
        cfg.sdpSemantics = .unifiedPlan
        cfg.bundlePolicy = .maxBundle

        let noConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc = WebRTCMedia.factory.peerConnection(with: cfg, constraints: noConstraints, delegate: nil)!
        let source = WebRTCMedia.factory.audioSource(with: noConstraints)
        audioTrack = WebRTCMedia.factory.audioTrack(with: source, trackId: "audio0")
        super.init()
        pc.add(audioTrack, streamIds: ["stream0"])
        pc.delegate = self
    }

    // MARK: - Outgoing: build a candidate-laden offer (fix #2)

    func createOffer() async throws -> String {
        let offer = try await withChecked { self.pc.offer(for: self.recvAudio, completionHandler: $0) }
        try await withChecked { self.pc.setLocalDescription(offer, completionHandler: $0) }
        await gatherICE()
        startStats()
        return pc.localDescription?.sdp ?? offer.sdp
    }

    func setAnswer(_ sdp: String) async throws {
        try await withChecked { self.pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp), completionHandler: $0) }
    }

    // MARK: - Incoming: strip the offer's candidates, answer, re-add (fix #1)

    func acceptOffer(_ remoteSdp: String) async throws -> String {
        let (stripped, held, _) = WebRTCMedia.stripOfferCandidates(remoteSdp)
        heldRemote = held
        try await withChecked { self.pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: stripped), completionHandler: $0) }
        let answer = try await withChecked { self.pc.answer(for: self.recvAudio, completionHandler: $0) }
        try await withChecked { self.pc.setLocalDescription(answer, completionHandler: $0) }
        await gatherICE()
        for h in heldRemote {   // fix #1: hand the held remote candidates back after our answer is set
            // RTCPeerConnection.add(candidate:) is async throws in modern libwebrtc (M125+).
            try await pc.add(RTCIceCandidate(sdp: String(h.line.dropFirst(2)), sdpMLineIndex: 0, sdpMid: h.mid))
        }
        startStats()
        return pc.localDescription?.sdp ?? answer.sdp
    }

    // MARK: - Controls

    func setMuted(_ muted: Bool) { audioTrack.isEnabled = !muted }
    // A minimal hold: stop sending audio. True SIP hold re-INVITEs with a=sendonly/inactive — TODO.
    func setHold(_ held: Bool) { audioTrack.isEnabled = !held }

    func close() {
        statsTimer?.invalidate(); statsTimer = nil
        pc.close()
    }

    // MARK: - fix #2: gather to a relay candidate (or complete, or a 4s cap), no trickle over SIP

    private func gatherICE() async {
        if pc.iceGatheringState == .complete || gatherDone { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            gatherCont = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in self?.finishGather() }
        }
    }
    private func finishGather() {
        gatherDone = true
        if let c = gatherCont { gatherCont = nil; c.resume() }
    }
    private func candidateIsEnough(_ sdp: String) -> Bool {
        if sdp.contains("typ relay") { return true }
        if relayOnly || hasTurn { return false }   // must wait for a relay candidate
        if sdp.contains("typ srflx") { return true }
        if sdp.contains("typ host") && !hasStun { return true }
        return false
    }

    private var recvAudio: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)
    }

    // MARK: - stats → CallQuality (FR-CALL-11)

    private func startStats() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.sampleStats() }
    }
    private func sampleStats() {
        pc.statistics { [weak self] report in
            guard let self else { return }
            var rtt: Int?; var jitter: Int?; var loss: Double?
            var received: UInt64 = 0; var lost: UInt64 = 0
            for (_, s) in report.statistics {
                if s.type == "candidate-pair", (s.values["nominated"] as? Bool) == true,
                   let t = s.values["currentRoundTripTime"] as? Double { rtt = Int(t * 1000) }
                if s.type == "inbound-rtp", (s.values["kind"] as? String) == "audio" {
                    received = (s.values["packetsReceived"] as? UInt64) ?? 0
                    lost = (s.values["packetsLost"] as? UInt64) ?? 0
                    if let j = s.values["jitter"] as? Double { jitter = Int(j * 1000) }
                }
            }
            if let prev = self.prevInbound, received > prev.received {
                let dR = Double(received - prev.received), dL = Double(lost - prev.lost)
                loss = dR + dL > 0 ? (dL / (dR + dL)) * 100 : 0
            }
            self.prevInbound = (received, lost)
            self.onQuality?(CallQuality(rttMs: rtt, jitterMs: jitter, lossPct: loss, mos: nil))
        }
    }

    // MARK: - fix #3 + #1 helpers (ports of ice.js)

    /// Expand a bare TURN URL to UDP/TCP/TLS so ICE can pick what the network allows.
    static func turnUrls(_ url: String) -> [String] {
        guard let host = url.split(separator: ":").dropFirst().first.map(String.init)?.split(separator: "?").first.map(String.init) else { return [url] }
        return ["turn:\(host):3478?transport=udp", "turn:\(host):3478?transport=tcp", "turns:\(host):5349?transport=tcp"]
    }

    /// Strip `a=candidate` / `a=end-of-candidates` from an inbound offer so the answerer gathers its own.
    static func stripOfferCandidates(_ sdp: String) -> (sdp: String, held: [(line: String, mid: String)], mid: String) {
        let lines = sdp.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let mid = lines.first { $0.hasPrefix("a=mid:") }.map { String($0.dropFirst(6)) } ?? "0"
        let heldLines = lines.filter { $0.hasPrefix("a=candidate") }
        guard !heldLines.isEmpty else { return (sdp, [], mid) }
        let kept = lines.filter { !$0.hasPrefix("a=candidate") && $0 != "a=end-of-candidates" }.joined(separator: "\r\n")
        return (kept, heldLines.map { (line: $0, mid: mid) }, mid)
    }

    // completion → async helper for the WebRTC ObjC API
    private func withChecked(_ body: @escaping (@escaping (RTCSessionDescription?, Error?) -> Void) -> Void) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            body { sdp, err in
                if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: err ?? InCallError.mediaFailed("sdp op failed")) }
            }
        }
    }
    private func withChecked(_ body: @escaping (@escaping (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            body { err in if let err { cont.resume(throwing: err) } else { cont.resume() } }
        }
    }
}

// MARK: - RTCPeerConnectionDelegate (candidate gather + state)

extension WebRTCMedia: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        if candidateIsEnough(candidate.sdp) { finishGather() }   // fix #2
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { finishGather() }
    }
    // Remaining required delegate methods (unused).
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
#endif
