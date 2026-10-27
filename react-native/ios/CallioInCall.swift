// iOS native module for @clarigoinfotech/callio-react-native (FR-SDK-02): React Native bridge <-> InCallSDK. Same calls as the
// Flutter plugin; events go out on one "CallioInCallEvent" channel as { event, ...payload }.
import Foundation
import React
import InCallSDK

@objc(CallioInCall)
final class CallioInCall: RCTEventEmitter, InCallClientDelegate {
    private var client: InCallClient?
    // Touched from React's module queue and from the SDK's main actor, so it lives outside actor isolation.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var hasListeners = false
        var pendingTokens: [String: CheckedContinuation<String, Error>] = [:]
        func with<T>(_ f: (Shared) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(self) }
    }
    private let shared = Shared()

    override static func requiresMainQueueSetup() -> Bool { false }
    override func supportedEvents() -> [String]! { ["CallioInCallEvent"] }
    nonisolated override func startObserving() { shared.with { $0.hasListeners = true } }
    nonisolated override func stopObserving() { shared.with { $0.hasListeners = false } }

    nonisolated private func emit(_ body: [String: Any?]) {
        guard shared.with({ $0.hasListeners }) else { return }
        sendEvent(withName: "CallioInCallEvent", body: body.compactMapValues { $0 })
    }

    // Run an async SDK call and settle the JS promise.
    private func run(_ reject: @escaping RCTPromiseRejectBlock, _ name: String, _ body: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await body() } catch { reject(name, "\(error)", error) }
        }
    }

    // ---- token round trip: native asks JS, JS answers with provideToken ----
    nonisolated private func tokenFromJS() async throws -> String {
        let id = UUID().uuidString
        let token: String = try await withCheckedThrowingContinuation { cont in
            self.register(id, cont)
            emit(["event": "tokenRequest", "requestId": id])
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.settleToken(id, .failure(InCallError.tokenExpired))
            }
        }
        return token
    }
    nonisolated private func register(_ id: String, _ cont: CheckedContinuation<String, Error>) {
        shared.with { $0.pendingTokens[id] = cont }
    }
    nonisolated private func settleToken(_ id: String, _ result: Result<String, Error>) {
        let cont = shared.with { $0.pendingTokens.removeValue(forKey: id) }
        cont?.resume(with: result)
    }
    @objc nonisolated func provideToken(_ requestId: String, token: String?) {
        if let token, !token.isEmpty { settleToken(requestId, .success(token)) } else { settleToken(requestId, .failure(InCallError.tokenExpired)) }
    }

    @objc func start(_ baseUrl: String, forceRelay: Bool, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "start") {
            guard let url = URL(string: baseUrl) else { throw InCallError.network("invalid baseUrl") }
            let config = InCallConfig(baseURL: url, forceRelay: forceRelay) { try await self.tokenFromJS() }
            let c = InCallClient(config: config); c.delegate = self; self.client = c
            try await c.start()
            resolve(nil)
        }
    }
    @objc func stop(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "stop") { await self.client?.stop(); resolve(nil) }
    }
    @objc func dial(_ sipUser: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "dial") {
            guard let c = self.client else { throw InCallError.notRegistered }
            resolve(try await c.dial(self.contact(sipUser)).id)
        }
    }
    @objc func answer(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "answer") { try await self.client?.currentCall?.answer(); resolve(nil) }
    }
    @objc func decline(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "decline") { await self.client?.currentCall?.decline(); resolve(nil) }
    }
    @objc func hangup(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "hangup") { await self.client?.currentCall?.hangup(); resolve(nil) }
    }
    @objc func setMuted(_ muted: Bool, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "setMuted") { await self.client?.currentCall?.setMuted(muted); resolve(nil) }
    }
    @objc func setHold(_ held: Bool, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "setHold") { await self.client?.currentCall?.setHold(held); resolve(nil) }
    }
    @objc func sendDtmf(_ tone: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "sendDtmf") { await self.client?.currentCall?.sendDTMF(tone); resolve(nil) }
    }
    @objc func setAudioRoute(_ route: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "setAudioRoute") {
            guard let r = AudioRoute(rawValue: route) else { throw InCallError.mediaFailed("unknown route \(route)") }
            await self.client?.currentCall?.setAudioRoute(r); resolve(nil)
        }
    }
    @objc func sendText(_ to: String, text: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "sendText") {
            guard let c = self.client else { throw InCallError.notRegistered }
            resolve(try await c.thread(with: self.contact(to)).send(text: text).id)
        }
    }
    @objc func sendLocation(_ to: String, lat: Double, lng: Double, label: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "sendLocation") {
            guard let c = self.client else { throw InCallError.notRegistered }
            resolve(try await c.thread(with: self.contact(to)).sendLocation(SharedLocation(lat: lat, lng: lng, label: label)).id)
        }
    }
    @objc func setTyping(_ to: String, typing: Bool, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "setTyping") { await self.client?.thread(with: self.contact(to)).setTyping(typing); resolve(nil) }
    }
    @objc func callHistory(_ limit: Double, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "callHistory") {
            let h = try await self.client?.callHistory(limit: Int(limit)) ?? []
            resolve(h.map { ["callId": $0.callId, "peer": $0.peer, "peerDisplayName": $0.peerDisplayName,
                             "direction": $0.direction.rawValue, "outcome": $0.outcome, "durationSec": $0.durationSec, "at": $0.at] })
        }
    }
    @objc func registerPush(_ token: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(reject, "registerPush") { try await self.client?.push.register(voipToken: token); resolve(nil) }
    }

    private func contact(_ sip: String) -> Contact {
        client?.directory.first { $0.sipUser == sip || $0.name == sip }
            ?? Contact(name: sip, sipUser: sip, displayName: sip, userType: .customer)
    }

    // ---- InCallClientDelegate -> JS ----
    func client(_ c: InCallClient, registrationDidChange state: RegistrationState) { emit(["event": "registration", "state": state.rawValue]) }
    func client(_ c: InCallClient, didReceiveIncomingCall call: Call) {
        emit(["event": "incomingCall", "callId": call.id,
              "from": ["name": call.peer.name, "sipUser": call.peer.sipUser, "displayName": call.peer.displayName, "userType": call.peer.userType.rawValue]])
    }
    func client(_ c: InCallClient, callDidChangeState call: Call) { emit(["event": "callState", "callId": call.id, "state": Self.stateName(call.state)]) }
    func client(_ c: InCallClient, callQualityDidUpdate q: CallQuality) {
        emit(["event": "quality", "quality": ["rttMs": q.rttMs as Any, "jitterMs": q.jitterMs as Any, "lossPct": q.lossPct as Any, "mos": q.mos as Any]])
    }
    func client(_ c: InCallClient, didReceiveMessage m: Message, in thread: ChatThread) {
        emit(["event": "message", "peerSip": thread.peer.sipUser,
              "message": ["id": m.id, "from": m.from.rawValue, "text": m.text as Any,
                          "location": m.location.map { ["lat": $0.lat, "lng": $0.lng, "label": $0.label] } as Any, "status": m.status.rawValue]])
    }
    func client(_ c: InCallClient, audioRouteDidChange route: AudioRoute) { emit(["event": "audioRoute", "route": route.rawValue]) }
    func client(_ c: InCallClient, didFail error: InCallError) { emit(["event": "failure", "code": "\(error)", "message": "\(error)"]) }

    private static func stateName(_ s: CallState) -> String {
        switch s {
        case .initiating: return "initiating"; case .ringing: return "ringing"; case .connected: return "connected"
        case .onHold: return "onHold"; case .reconnecting: return "reconnecting"; case .ended: return "ended"
        }
    }
}
