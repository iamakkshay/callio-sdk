// iOS bridge for the incall_flutter plugin: MethodChannel + EventChannel <-> InCallSDK. Every Dart method in
// lib/src/incall.dart has a case here; every InCallClientDelegate callback becomes one event map
// { event: <name>, ...payload }. Errors come back as FlutterError with a stable code (contract section 7).
import AVFoundation
import Flutter
import InCallSDK

public class InCallFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var channel: FlutterMethodChannel?
    private var sink: FlutterEventSink?
    private var client: InCallClient?
    private var invites: [String: ConferenceInvite] = [:]   // room -> invite, until joined
    #if os(iOS)
    private var callKit: InCallCallKit?
    #endif

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = InCallFlutterPlugin()
        let channel = FlutterMethodChannel(name: "incall_flutter", binaryMessenger: registrar.messenger())
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
        FlutterEventChannel(name: "incall_flutter/events", binaryMessenger: registrar.messenger()).setStreamHandler(instance)
    }

    public func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
    public func onCancel(withArguments _: Any?) -> FlutterError? { sink = nil; return nil }

    private struct BridgeError: Error { let code: String; let message: String }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        Task { @MainActor in
            do {
                result(try await self.dispatch(call.method, args))
            } catch let e as BridgeError {
                result(FlutterError(code: e.code, message: e.message, details: nil))
            } catch {
                result(FlutterError(code: Self.errorCode(error), message: "\(error)", details: nil))
            }
        }
    }

    @MainActor
    private func dispatch(_ method: String, _ args: [String: Any]) async throws -> Any? {
        switch method {
        case "start":
            guard let s = args["baseUrl"] as? String, let baseURL = URL(string: s) else { throw BridgeError(code: "invalidArgument", message: "baseUrl is required") }
            if let old = client { old.removeObserver(self); await old.stop() }
            let config = InCallConfig(baseURL: baseURL,
                                      forceRelay: args["forceRelay"] as? Bool ?? false,
                                      disconnectInBackground: args["disconnectInBackground"] as? Bool ?? true,
                                      allowInsecureTransport: args["allowInsecureTransport"] as? Bool ?? false) { [weak self] in
                guard let self else { throw InCallError.tokenExpired }
                return try await self.tokenFromDart()
            }
            let c = InCallClient(config: config)
            c.addObserver(self)
            client = c
            #if os(iOS)
            if args["nativeCallUi"] as? Bool ?? true {
                let ck = InCallCallKit(client: c)
                ck.registerForVoIPPushes()   // the VoIP token is registered with the platform automatically
                callKit = ck
            } else {
                callKit = nil
            }
            #endif
            try await c.start()
            return nil
        case "stop":
            await client?.stop(); invites.removeAll(); return nil
        case "session":
            guard let s = client?.session else { return nil }
            return ["tenant": s.tenant, "user": s.user, "sipUser": s.sipUser, "userType": s.userType.rawValue,
                    "features": ["calling": s.features.calling, "chat": s.features.chat, "location": s.features.location, "recording": s.features.recording],
                    "directory": s.directory.map(Self.contactMap), "peers": s.peers.map(Self.contactMap),
                    "transferTargets": s.transferTargets.map(Self.contactMap)] as [String: Any]
        case "requestPermissions":
            let mic: Bool = await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
            return ["microphone": mic, "notifications": true, "bluetooth": true]
        case "sdkVersion":
            return InCallSDKVersion.current

        // calls
        case "dial":
            guard let sip = args["sipUser"] as? String, !sip.isEmpty else { throw BridgeError(code: "invalidArgument", message: "sipUser is required") }
            return try await requireClient().dial(contact(sip)).id
        case "answer":
            try await requireCall().answer(); return nil
        case "decline":
            await client?.currentCall?.decline(); return nil
        case "cancel":
            await client?.currentCall?.cancel(); return nil
        case "hangup":
            #if os(iOS)
            if let ck = callKit { try await ck.endCurrentCall(); return nil }
            #endif
            await client?.currentCall?.hangup(); return nil
        case "setMuted":
            let muted = args["muted"] as? Bool ?? false
            #if os(iOS)
            if let ck = callKit { _ = try requireCall(); try await ck.setMuted(muted); return nil }
            #endif
            try await requireCall().setMuted(muted); return nil
        case "setHold":
            try await requireCall().setHold(args["held"] as? Bool ?? false); return nil
        case "sendDtmf":
            try await requireCall().sendDTMF(args["tone"] as? String ?? ""); return nil
        case "setAudioRoute":
            guard let route = AudioRoute(rawValue: args["route"] as? String ?? "") else { throw BridgeError(code: "invalidArgument", message: "unknown audio route") }
            if let call = client?.currentCall { await call.setAudioRoute(route) } else {
                #if os(iOS)
                try requireClient().audio.set(route)
                #endif
            }
            return nil
        case "audioRoutes":
            #if os(iOS)
            let audio = try requireClient().audio
            return ["available": audio.available.map(\.rawValue), "current": audio.current.rawValue] as [String: Any]
            #else
            return ["available": ["earpiece", "speaker"], "current": "earpiece"]
            #endif
        case "transfer":
            try await requireCall().transfer(to: contact(args["sipUser"] as? String ?? "")); return nil
        case "joinConference":
            guard let room = args["room"] as? String, let invite = invites.removeValue(forKey: room) else {
                throw BridgeError(code: "invalidArgument", message: "no conference invite for that room")
            }
            return try await requireClient().joinConference(invite).id

        // chat / location
        case "sendMessage":
            guard let to = args["to"] as? String else { throw BridgeError(code: "invalidArgument", message: "to is required") }
            let thread = try requireClient().thread(with: contact(to))
            if let loc = args["location"] as? [String: Any], let lat = (loc["lat"] as? NSNumber)?.doubleValue, let lng = (loc["lng"] as? NSNumber)?.doubleValue {
                return try await thread.sendLocation(SharedLocation(lat: lat, lng: lng, label: loc["label"] as? String ?? "Shared location")).id
            }
            return try await thread.send(text: args["text"] as? String ?? "").id
        case "setTyping":
            await client?.thread(with: contact(args["to"] as? String ?? "")).setTyping(args["typing"] as? Bool ?? false); return nil
        case "messages":
            guard let c = client else { return [Any]() }
            return c.thread(with: contact(args["peer"] as? String ?? "")).messages.map(Self.messageMap)

        // presence
        case "refreshPresence":
            let c = try requireClient()
            let users = (args["sipUsers"] as? [String])?.map(contact)
            await c.refreshPresence(for: users)
            return c.presence
        case "startPresenceUpdates":
            let ms = (args["everyMs"] as? NSNumber)?.doubleValue ?? 30_000
            try requireClient().startPresenceUpdates(every: ms / 1000); return nil
        case "stopPresenceUpdates":
            client?.stopPresenceUpdates(); return nil

        // history / push
        case "callHistory":
            let limit = (args["limit"] as? NSNumber)?.intValue ?? 50
            return try await requireClient().callHistory(limit: limit).map { h -> [String: Any?] in
                ["callId": h.callId, "peer": h.peer, "peerDisplayName": h.peerDisplayName, "peerSipUser": h.peerSipUser,
                 "direction": h.direction.rawValue, "outcome": h.outcome, "durationSec": h.durationSec, "at": h.at]
            }
        case "registerPush":
            try await requireClient().push.register(voipToken: args["token"] as? String ?? ""); return nil
        case "unregisterPush":
            try await client?.push.unregister(); return nil
        case "handlePush":
            return false   // VoIP pushes arrive through PushKit (InCallCallKit), not through Dart
        default:
            return FlutterMethodNotImplemented
        }
    }

    @MainActor private func requireClient() throws -> InCallClient {
        guard let c = client else { throw InCallError.notRegistered }
        return c
    }

    @MainActor private func requireCall() throws -> Call {
        guard let c = client?.currentCall else { throw BridgeError(code: "noActiveCall", message: "no call in progress") }
        return c
    }

    // Native -> Dart: fetch a fresh token. No answer in 20 s, or an empty one, is a token failure.
    @MainActor private func tokenFromDart() async throws -> String {
        let once = Once()
        let token: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            once.cont = cont
            self.channel?.invokeMethod("getToken", arguments: nil) { res in once.resume(res as? String) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { once.resume(nil) }
        }
        guard let t = token, !t.isEmpty else { throw InCallError.tokenExpired }
        return t
    }

    private final class Once {
        var cont: CheckedContinuation<String?, Never>?
        func resume(_ v: String?) { cont?.resume(returning: v); cont = nil }
    }

    @MainActor private func contact(_ sip: String) -> Contact {
        let known = (client?.directory ?? []) + (client?.session?.peers ?? [])
        return known.first { $0.sipUser == sip || $0.name == sip }
            ?? Contact(name: sip, sipUser: sip, displayName: sip, userType: .customer)
    }

    private static func contactMap(_ c: Contact) -> [String: Any] {
        ["name": c.name, "sipUser": c.sipUser, "displayName": c.displayName, "userType": c.userType.rawValue]
    }

    private static func messageMap(_ m: Message) -> [String: Any?] {
        ["id": m.id, "from": m.from.rawValue, "text": m.text,
         "location": m.location.map { ["lat": $0.lat, "lng": $0.lng, "label": $0.label] as [String: Any] }, "status": m.status.rawValue]
    }

    private func emit(_ map: [String: Any?]) {
        // Flutter's codec wants NSNull, not nil, for missing values.
        let clean = map.mapValues { $0 ?? NSNull() }
        DispatchQueue.main.async { self.sink?(clean) }
    }

    private static func stateName(_ s: CallState) -> String {
        switch s {
        case .initiating: return "initiating"; case .ringing: return "ringing"; case .connected: return "connected"
        case .onHold: return "onHold"; case .reconnecting: return "reconnecting"; case .ended: return "ended"
        }
    }

    static func errorCode(_ e: Error) -> String {
        guard let e = e as? InCallError else { return (e as? URLError) != nil ? "network" : "unknown" }
        switch e {
        case .notRegistered: return "notRegistered"
        case .micPermission: return "micPermission"
        case .peerUnreachable: return "peerUnreachable"
        case .busy: return "busy"
        case .tokenExpired: return "tokenExpired"
        case .featureDisabled: return "featureDisabled"
        case .network: return "network"
        case .mediaFailed: return "mediaFailed"
        }
    }
}

// ---- InCallClientDelegate -> EventChannel ----
extension InCallFlutterPlugin: InCallClientDelegate {
    public func client(_ c: InCallClient, registrationDidChange state: RegistrationState) {
        emit(["event": "registration", "state": state.rawValue])
    }
    public func client(_ c: InCallClient, didReceiveIncomingCall call: Call) {
        emit(["event": "incomingCall", "callId": call.id, "from": Self.contactMap(call.peer)])
    }
    public func client(_ c: InCallClient, callDidChangeState call: Call) {
        var reason: String?
        if case .ended(let r) = call.state { reason = r.rawValue }
        emit(["event": "callState", "callId": call.id, "state": Self.stateName(call.state), "reason": reason,
              "direction": call.direction.rawValue, "peer": Self.contactMap(call.peer), "muted": call.isMuted, "held": call.isOnHold])
    }
    public func client(_ c: InCallClient, callQualityDidUpdate q: CallQuality) {
        let quality: [String: Any] = ["rttMs": q.rttMs ?? NSNull(), "jitterMs": q.jitterMs ?? NSNull(), "lossPct": q.lossPct ?? NSNull(), "mos": q.mos ?? NSNull()]
        emit(["event": "quality", "callId": c.currentCall?.id, "quality": quality])
    }
    public func client(_ c: InCallClient, didReceiveMessage m: Message, in thread: ChatThread) {
        emit(["event": "message", "peerSip": thread.peer.sipUser, "message": Self.messageMap(m).mapValues { $0 ?? NSNull() }])
    }
    public func client(_ c: InCallClient, messageStatusDidChange m: Message) {
        emit(["event": "messageStatus", "messageId": m.id, "status": m.status.rawValue])
    }
    public func client(_ c: InCallClient, audioRouteDidChange route: AudioRoute) {
        emit(["event": "audioRoute", "route": route.rawValue])
    }
    public func client(_ c: InCallClient, presenceDidChange presence: [String: Bool]) {
        emit(["event": "presence", "presence": presence])
    }
    public func client(_ c: InCallClient, didReceiveConferenceInvite invite: ConferenceInvite) {
        invites[invite.room] = invite
        emit(["event": "conferenceInvite", "room": invite.room, "from": Self.contactMap(invite.from), "with": invite.with])
    }
    public func client(_ c: InCallClient, conferenceDidStart call: Call) {
        emit(["event": "conferenceStarted", "callId": call.id, "room": call.peer.sipUser])
    }
    public func client(_ c: InCallClient, didFail error: InCallError) {
        emit(["event": "failure", "code": Self.errorCode(error), "message": "\(error)"])
    }
}
