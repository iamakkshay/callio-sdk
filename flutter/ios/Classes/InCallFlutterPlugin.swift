// iOS bridge for the incall_flutter plugin: MethodChannel + EventChannel <-> InCallSDK. REFERENCE —
// compiles once InCallSDK is a dependency of this plugin's podspec.
import Flutter
import InCallSDK

public class InCallFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, InCallClientDelegate {
    private var channel: FlutterMethodChannel?
    private var sink: FlutterEventSink?
    private var client: InCallClient?
    private var tokenCompletion: ((String) -> Void)?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = InCallFlutterPlugin()
        let channel = FlutterMethodChannel(name: "incall_flutter", binaryMessenger: registrar.messenger())
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
        FlutterEventChannel(name: "incall_flutter/events", binaryMessenger: registrar.messenger()).setStreamHandler(instance)
    }

    public func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
    public func onCancel(withArguments _: Any?) -> FlutterError? { sink = nil; return nil }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        Task { @MainActor in
            do {
                switch call.method {
                case "start":
                    let baseURL = URL(string: args["baseUrl"] as! String)!
                    let config = InCallConfig(baseURL: baseURL, forceRelay: args["forceRelay"] as? Bool ?? false) {
                        try await self.tokenFromDart()
                    }
                    let c = InCallClient(config: config); c.delegate = self; self.client = c
                    try await c.start()
                    result(nil)
                case "stop": await self.client?.stop(); result(nil)
                case "dial":
                    let contact = self.contact(forSip: args["sipUser"] as! String)
                    let cCall = try await self.client?.dial(contact)
                    result(cCall?.id)
                case "answer": try await self.client?.currentCall?.answer(); result(nil)
                case "decline": await self.client?.currentCall?.decline(); result(nil)
                case "hangup": await self.client?.currentCall?.hangup(); result(nil)
                case "setMuted": await self.client?.currentCall?.setMuted(args["muted"] as? Bool ?? false); result(nil)
                case "setHold": await self.client?.currentCall?.setHold(args["held"] as? Bool ?? false); result(nil)
                case "setAudioRoute":
                    if let r = AudioRoute(rawValue: args["route"] as? String ?? "") { await self.client?.currentCall?.setAudioRoute(r) }
                    result(nil)
                case "sendDtmf": await self.client?.currentCall?.sendDTMF(args["tone"] as? String ?? ""); result(nil)
                case "sendMessage":
                    let contact = self.contact(forSip: args["to"] as! String)
                    let thread = self.client?.thread(with: contact)
                    if let loc = args["location"] as? [String: Any] {
                        let m = try await thread?.sendLocation(SharedLocation(lat: loc["lat"] as! Double, lng: loc["lng"] as! Double, label: loc["label"] as? String ?? "Shared location"))
                        result(m?.id)
                    } else {
                        let m = try await thread?.send(text: args["text"] as? String ?? "")
                        result(m?.id)
                    }
                case "setTyping":
                    await self.client?.thread(with: self.contact(forSip: args["to"] as! String)).setTyping(args["typing"] as? Bool ?? false)
                    result(nil)
                case "callHistory":
                    let h = try await self.client?.callHistory(limit: args["limit"] as? Int ?? 50) ?? []
                    result(h.map { ["callId": $0.callId, "peer": $0.peer, "peerDisplayName": $0.peerDisplayName,
                                    "direction": $0.direction.rawValue, "outcome": $0.outcome, "durationSec": $0.durationSec, "at": $0.at] })
                case "registerPush": try? await self.client?.push.register(voipToken: args["token"] as? String ?? ""); result(nil)
                default: result(FlutterMethodNotImplemented)
                }
            } catch { result(FlutterError(code: call.method, message: "\(error)", details: nil)) }
        }
    }

    // Native -> Dart: fetch a fresh token.
    private func tokenFromDart() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                self.channel?.invokeMethod("getToken", arguments: nil) { res in cont.resume(returning: res as? String ?? "") }
            }
        }
    }

    private func contact(forSip sip: String) -> Contact {
        client?.directory.first { $0.sipUser == sip || $0.name == sip }
            ?? Contact(name: sip, sipUser: sip, displayName: sip, userType: .customer)
    }

    private func emit(_ map: [String: Any?]) { DispatchQueue.main.async { self.sink?(map) } }

    // ---- InCallClientDelegate -> EventChannel ----
    public func client(_ c: InCallClient, registrationDidChange state: RegistrationState) { emit(["event": "registration", "state": state.rawValue]) }
    public func client(_ c: InCallClient, didReceiveIncomingCall call: Call) {
        emit(["event": "incomingCall", "callId": call.id,
              "from": ["name": call.peer.name, "sipUser": call.peer.sipUser, "displayName": call.peer.displayName, "userType": call.peer.userType.rawValue]])
    }
    public func client(_ c: InCallClient, callDidChangeState call: Call) { emit(["event": "callState", "callId": call.id, "state": Self.stateName(call.state)]) }
    public func client(_ c: InCallClient, callQualityDidUpdate q: CallQuality) {
        emit(["event": "quality", "quality": ["rttMs": q.rttMs as Any, "jitterMs": q.jitterMs as Any, "lossPct": q.lossPct as Any, "mos": q.mos as Any]])
    }
    public func client(_ c: InCallClient, didReceiveMessage m: Message, in thread: ChatThread) {
        emit(["event": "message", "peerSip": thread.peer.sipUser,
              "message": ["id": m.id, "from": m.from.rawValue, "text": m.text as Any,
                          "location": m.location.map { ["lat": $0.lat, "lng": $0.lng, "label": $0.label] } as Any, "status": m.status.rawValue]])
    }
    public func client(_ c: InCallClient, audioRouteDidChange route: AudioRoute) { emit(["event": "audioRoute", "route": route.rawValue]) }
    public func client(_ c: InCallClient, didFail error: InCallError) { emit(["event": "failure", "code": "\(error)", "message": "\(error)"]) }

    private static func stateName(_ s: CallState) -> String {
        switch s {
        case .initiating: return "initiating"; case .ringing: return "ringing"; case .connected: return "connected"
        case .onHold: return "onHold"; case .reconnecting: return "reconnecting"; case .ended: return "ended"
        }
    }
}
