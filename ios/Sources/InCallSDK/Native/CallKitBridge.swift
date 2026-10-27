// The native call experience on iOS (FR-CALL-02/03/04): CallKit's system call UI (lock screen, Recents, car,
// Siri), VoIP pushes that ring a killed app, and the audio session CallKit owns during a call.
//
//   let callKit = InCallCallKit(client: client, options: .init(iconTemplateImageData: logoPNG))
//   callKit.registerForVoIPPushes()            // at launch
//   try await callKit.startCall(to: contact)   // outgoing calls through CallKit too
//
// The host app declares the `voip` background mode and the Push Notifications capability. The bridge listens to
// the client as an observer, so the app keeps its own delegate.
#if canImport(CallKit) && canImport(PushKit) && os(iOS)
import AVFoundation
import CallKit
import PushKit
#if canImport(WebRTC)
import WebRTC
#endif

@MainActor
public final class InCallCallKit: NSObject {
    public struct Options {
        public var iconTemplateImageData: Data?
        public var ringtoneSound: String?
        public var includesCallsInRecents = true
        /// A push whose call never arrives over SIP (caller hung up first) is ended after this long.
        public var pushedCallTimeout: TimeInterval = 30
        public init(iconTemplateImageData: Data? = nil, ringtoneSound: String? = nil) {
            self.iconTemplateImageData = iconTemplateImageData; self.ringtoneSound = ringtoneSound
        }
    }

    private let client: InCallClient
    private let options: Options
    private let provider: CXProvider
    private let controller = CXCallController()
    private let voipRegistry = PKPushRegistry(queue: .main)

    private var uuidByCallId: [String: UUID] = [:]
    private var callIdByUUID: [UUID: String] = [:]
    private var pushedUUID: UUID?                    // reported from a VoIP push, waiting for the INVITE
    private var dialing: [UUID: Contact] = [:]       // CXStartCallAction requested, not yet performed
    private var endedLocally: Set<UUID> = []         // the user ended it in CallKit: don't report it back
    private var pushHandler: VoIPPushHandler?
    /// Whether a call is in progress, readable from the push queue.
    private final class Flag: @unchecked Sendable { private let lock = NSLock(); private var v = false
        var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } } }
    private let busyFlag = Flag()

    public init(client: InCallClient, options: Options = Options()) {
        self.client = client
        self.options = options
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.supportedHandleTypes = [.generic]
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.includesCallsInRecents = options.includesCallsInRecents
        cfg.iconTemplateImageData = options.iconTemplateImageData
        cfg.ringtoneSound = options.ringtoneSound
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
        client.addObserver(self)
        #if canImport(WebRTC)
        // CallKit activates the audio session; WebRTC must wait for it rather than activate its own.
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        #endif
    }

    /// Start receiving VoIP pushes (call at launch). The token is registered with the platform automatically.
    public func registerForVoIPPushes() {
        let h = makePushHandler()
        pushHandler = h
        voipRegistry.delegate = h
        voipRegistry.desiredPushTypes = [.voIP]
    }

    /// Place a call through CallKit, so it shows in the system UI and Recents like a phone call.
    public func startCall(to contact: Contact) async throws {
        let uuid = UUID()
        dialing[uuid] = contact
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: contact.sipUser))
        action.contactIdentifier = contact.displayName
        do { try await controller.request(CXTransaction(action: action)) } catch { dialing[uuid] = nil; throw error }
    }

    /// End the current call through CallKit (keeps the system UI in step).
    public func endCurrentCall() async throws {
        guard let id = client.currentCall?.id, let uuid = uuidByCallId[id] else { await client.currentCall?.hangup(); return }
        try await controller.request(CXTransaction(action: CXEndCallAction(call: uuid)))
    }

    /// Mute through CallKit so the system UI's mute button matches.
    public func setMuted(_ muted: Bool) async throws {
        guard let id = client.currentCall?.id, let uuid = uuidByCallId[id] else { await client.currentCall?.setMuted(muted); return }
        try await controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted)))
    }

    private func bind(_ uuid: UUID, _ callId: String) { uuidByCallId[callId] = uuid; callIdByUUID[uuid] = callId; busyFlag.value = true }
    private func forget(_ uuid: UUID) {
        if let id = callIdByUUID.removeValue(forKey: uuid) { uuidByCallId[id] = nil }
        endedLocally.remove(uuid)
        if pushedUUID == uuid { pushedUUID = nil }
        busyFlag.value = !callIdByUUID.isEmpty
    }
    private func call(for uuid: UUID) -> Call? {
        guard let id = callIdByUUID[uuid], let c = client.currentCall, c.id == id else { return nil }
        return c
    }

    private func reportIncoming(_ uuid: UUID, name: String, handle: String, completion: ((Error?) -> Void)? = nil) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = name
        update.hasVideo = false
        update.supportsDTMF = true
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            Task { @MainActor in completion?(error) }
        }
    }
}

// MARK: - PushKit

// iOS terminates the app unless every VoIP push reports a call to CallKit before the delegate returns, so the
// report happens here, synchronously on the push queue; the bookkeeping then hops to the main actor.
private final class VoIPPushHandler: NSObject, PKPushRegistryDelegate {
    let provider: CXProvider
    var onToken: (String) -> Void = { _ in }
    /// The push was reported as `uuid`; returns false when the bridge can't take the call (already in one).
    var onIncoming: (UUID, PushService.IncomingCallPush, @escaping () -> Void) -> Void = { _, _, done in done() }
    var busy: () -> Bool = { false }

    init(provider: CXProvider) { self.provider = provider }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        onToken(pushCredentials.token.map { String(format: "%02x", $0) }.joined())
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        let uuid = UUID()
        let push = PushService.parse(payload.dictionaryPayload)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: push?.callId ?? "unknown")
        update.localizedCallerName = push?.fromDisplayName ?? "Unknown"
        update.hasVideo = false
        update.supportsDTMF = true
        update.supportsHolding = true
        let reject = push == nil || busy()
        provider.reportNewIncomingCall(with: uuid, update: update) { [self] error in
            if reject || error != nil {
                // A bad push, or already in a call: iOS still needed the report; end it at once.
                if error == nil { provider.reportCall(with: uuid, endedAt: nil, reason: push == nil ? .failed : .unanswered) }
                completion(); return
            }
            onIncoming(uuid, push!, completion)
        }
    }
}

extension InCallCallKit {
    private func makePushHandler() -> VoIPPushHandler {
        let h = VoIPPushHandler(provider: provider)
        h.onToken = { hex in Task { @MainActor in try? await self.client.push.register(voipToken: hex) } }
        h.busy = { [weak self] in self?.busyFlag.value ?? false }
        h.onIncoming = { uuid, push, completion in
            Task { @MainActor in
                self.pushedUUID = uuid
                self.bind(uuid, push.callId)
                completion()
                try? await self.client.start()   // register so the INVITE can arrive
                try? await Task.sleep(nanoseconds: UInt64(self.options.pushedCallTimeout * 1_000_000_000))
                if self.pushedUUID == uuid {      // the caller gave up before the INVITE reached us
                    self.provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
                    self.forget(uuid)
                }
            }
        }
        return h
    }
}

// MARK: - CallKit actions from the system UI

extension InCallCallKit: CXProviderDelegate {
    nonisolated public func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            await self.client.currentCall?.hangup()
            self.uuidByCallId.removeAll(); self.callIdByUUID.removeAll(); self.dialing.removeAll(); self.endedLocally.removeAll(); self.pushedUUID = nil; self.busyFlag.value = false
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            guard let contact = self.dialing.removeValue(forKey: action.callUUID) else { action.fail(); return }
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
            do {
                let call = try await self.client.dial(contact)
                self.bind(action.callUUID, call.id)
                action.fulfill()
            } catch { action.fail() }
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            guard let call = self.call(for: action.callUUID) else { action.fail(); return }
            do { try await call.answer(); action.fulfill() } catch { action.fail() }
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            self.endedLocally.insert(action.callUUID)
            if let call = self.call(for: action.callUUID) {
                if call.direction == .incoming && call.state == .ringing { await call.decline() } else { await call.hangup() }
            }
            action.fulfill()
            self.forget(action.callUUID)
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in await self.call(for: action.callUUID)?.setMuted(action.isMuted); action.fulfill() }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Task { @MainActor in await self.call(for: action.callUUID)?.setHold(action.isOnHold); action.fulfill() }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        Task { @MainActor in
            if let call = self.call(for: action.callUUID) { for d in action.digits { await call.sendDTMF(String(d)) } }
            action.fulfill()
        }
    }

    nonisolated public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        #if canImport(WebRTC)
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        #endif
        Task { @MainActor in try? AudioRouter.shared.configureForCall() }
    }

    nonisolated public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        #if canImport(WebRTC)
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        #endif
    }
}

// MARK: - SDK → CallKit: keep the system UI in step with the call

extension InCallCallKit: InCallClientDelegate {
    public func client(_ client: InCallClient, didReceiveIncomingCall call: Call) {
        if let uuid = pushedUUID {
            // The push we already reported: attach the real call to it (ids can differ between push and INVITE).
            if let old = callIdByUUID[uuid] { uuidByCallId[old] = nil }
            bind(uuid, call.id); pushedUUID = nil
        } else if uuidByCallId[call.id] == nil {
            // App in the foreground, no push: report it now so the system UI rings.
            let uuid = UUID()
            bind(uuid, call.id)
            reportIncoming(uuid, name: call.peer.displayName, handle: call.peer.sipUser) { error in if error != nil { self.forget(uuid) } }
        }
    }

    public func client(_ client: InCallClient, callDidChangeState call: Call) {
        guard let uuid = uuidByCallId[call.id] else { return }
        switch call.state {
        case .connected where call.direction == .outgoing:
            provider.reportOutgoingCall(with: uuid, connectedAt: nil)
        case .ended(let reason):
            if !endedLocally.contains(uuid) { provider.reportCall(with: uuid, endedAt: nil, reason: Self.cxReason(reason)) }
            forget(uuid)
        default: break
        }
    }

    nonisolated static func cxReason(_ r: CallEndReason) -> CXCallEndedReason {
        switch r {
        case .declined: return .declinedElsewhere
        case .busy, .unreachable: return .failed
        case .missed, .noAnswer: return .unanswered
        case .ended: return .remoteEnded
        }
    }
}
#endif
