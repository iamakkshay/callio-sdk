import Foundation
import Network
#if os(iOS)
import UIKit
#endif

/// Receives SDK events, delivered on the main actor (contract §4). All methods are optional via the
/// default no-op extension below.
@MainActor
public protocol InCallClientDelegate: AnyObject {
    func client(_ client: InCallClient, registrationDidChange state: RegistrationState)
    func client(_ client: InCallClient, didReceiveIncomingCall call: Call)
    func client(_ client: InCallClient, callDidChangeState call: Call)
    func client(_ client: InCallClient, callQualityDidUpdate quality: CallQuality)
    func client(_ client: InCallClient, didReceiveMessage message: Message, in thread: ChatThread)
    func client(_ client: InCallClient, messageStatusDidChange message: Message)
    func client(_ client: InCallClient, didFail error: InCallError)
    /// The call's audio moved (speaker, earpiece, Bluetooth), by the user or by a headset coming or going (iOS).
    func client(_ client: InCallClient, audioRouteDidChange route: AudioRoute)
    /// FR-SDK-05: contacts came online or went offline (sipUser → connected), while presence updates run.
    func client(_ client: InCallClient, presenceDidChange presence: [String: Bool])
    /// Someone invites you into a 3-way call: show it, and call `joinConference(_:)` to join.
    func client(_ client: InCallClient, didReceiveConferenceInvite invite: ConferenceInvite)
    /// The SDK dialled into a 3-way call by itself (the person you were talking to moved the call there).
    func client(_ client: InCallClient, conferenceDidStart call: Call)
}

public extension InCallClientDelegate {
    func client(_ client: InCallClient, registrationDidChange state: RegistrationState) {}
    func client(_ client: InCallClient, didReceiveIncomingCall call: Call) {}
    func client(_ client: InCallClient, callDidChangeState call: Call) {}
    func client(_ client: InCallClient, callQualityDidUpdate quality: CallQuality) {}
    func client(_ client: InCallClient, didReceiveMessage message: Message, in thread: ChatThread) {}
    func client(_ client: InCallClient, messageStatusDidChange message: Message) {}
    func client(_ client: InCallClient, didFail error: InCallError) {}
    func client(_ client: InCallClient, audioRouteDidChange route: AudioRoute) {}
    func client(_ client: InCallClient, presenceDidChange presence: [String: Bool]) {}
    func client(_ client: InCallClient, didReceiveConferenceInvite invite: ConferenceInvite) {}
    func client(_ client: InCallClient, conferenceDidStart call: Call) {}
}

/// The headless entry point (contract §3). One long-lived instance per signed-in user: it owns
/// registration, the session, the active call, and chat threads. An optional prebuilt UI layer
/// (`InCallUI`, not in this skeleton) can be built on top.
@MainActor
public final class InCallClient {
    public weak var delegate: InCallClientDelegate?

    /// Extra listeners besides `delegate` — e.g. the CallKit bridge — so components don't steal the app's delegate.
    /// Held weakly; `removeObserver` or deallocation stops delivery.
    public func addObserver(_ o: InCallClientDelegate) { observers.removeAll { $0.ref == nil || $0.ref === o }; observers.append(WeakObserver(ref: o)) }
    public func removeObserver(_ o: InCallClientDelegate) { observers.removeAll { $0.ref == nil || $0.ref === o } }
    private struct WeakObserver { weak var ref: InCallClientDelegate? }
    private var observers: [WeakObserver] = []
    private func notify(_ f: (InCallClientDelegate) -> Void) {
        if let d = delegate { f(d) }
        for o in observers { if let r = o.ref, r !== delegate { f(r) } }
    }

    public private(set) var registrationState: RegistrationState = .offline {
        didSet { notify { $0.client(self, registrationDidChange: registrationState) } }
    }
    public private(set) var session: Session?
    public private(set) var currentCall: Call?

    public var features: Features { session?.features ?? Features() }
    public var userType: UserType? { session?.userType }
    public var directory: [Contact] { session?.directory ?? [] }

    private let config: InCallConfig
    private let api: PlatformAPI
    fileprivate var drainingHeld = false   // a held-message handover is running (FR-CHAT-03)
    /// This install's device id, sent as X-Device-Id: pass it to your server so it can request a token for this
    /// device only (POST /api/v1/tokens with deviceId).
    public let deviceId: String
    private let transport: any SIPTransport
    public let push: PushService

    private var threads: [String: ChatThread] = [:]   // keyed by peer sipUser

    public convenience init(config: InCallConfig) {
        // Real SIP-over-WSS signalling (registration + chat work); calls await the WebRTC media layer.
        self.init(config: config, transport: SignallingSIPTransport())
    }

    // Designated init; `transport` is internal (the native WebRTC/SIP transport or a test double).
    init(config: InCallConfig, transport: any SIPTransport) {
        self.config = config
        let deviceId = Self.stableDeviceId()
        self.deviceId = deviceId
        self.api = PlatformAPI(baseURL: config.baseURL, tokenProvider: config.tokenProvider, deviceId: deviceId)
        self.transport = transport
        self.push = PushService(api: api, deviceId: deviceId)
        self.transport.events = self
        #if os(iOS)
        AudioRouter.shared.onChange = { [weak self] route in
            guard let self else { return }
            self.notify { $0.client(self, audioRouteDidChange: route) }
        }
        #endif
    }

    #if os(iOS)
    /// Call audio routing: `audio.available`, `audio.current`, `audio.set(.speaker)` (FR-CALL-04).
    public var audio: AudioRouter { .shared }
    #endif

    // MARK: presence (FR-SDK-05)

    /// Who is connected now (sipUser → true/false), as of the last refresh.
    public private(set) var presence: [String: Bool] = [:]
    private var presenceTask: Task<Void, Never>?

    /// Ask once for these contacts (default: the directory). Calls `presenceDidChange` if anything changed.
    public func refreshPresence(for contacts: [Contact]? = nil) async {
        let users = (contacts ?? directory).map(\.sipUser)
        guard !users.isEmpty, let got = try? await api.presence(users) else { return }
        var next = presence
        for (k, v) in got { if let v { next[k] = v } }
        if next != presence { presence = next; notify { $0.client(self, presenceDidChange: next) } }
    }
    /// Keep presence fresh while the app shows contacts.
    public func startPresenceUpdates(every seconds: TimeInterval = 30) {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPresence()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }
    public func stopPresenceUpdates() { presenceTask?.cancel(); presenceTask = nil }

    // MARK: background (NFR-13)

    private var wantsConnection = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// In the background with no call, drop the socket (pushes ring the phone instead); reconnect in front.
    // Staying reachable: reconnect after a drop, with growing gaps (1, 2, 4 … 30 s); and at once when the network changes.
    private var offlineByChoice = false
    private var reconnectTask: Task<Void, Never>?
    func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { @MainActor [weak self] in
            var attempt = 0
            while let self, self.wantsConnection, !self.offlineByChoice, self.registrationState != .registered {
                try? await Task.sleep(nanoseconds: UInt64(min(30, 1 << min(attempt, 5))) * 1_000_000_000)
                guard self.wantsConnection, !self.offlineByChoice else { break }
                try? await self.start()
                attempt += 1
            }
            self?.reconnectTask = nil
        }
    }
    private var pathMonitor: NWPathMonitor?
    private var lastInterfaces: [NWInterface.InterfaceType] = []
    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let kinds = path.availableInterfaces.map(\.type)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = !self.lastInterfaces.isEmpty && kinds.first != self.lastInterfaces.first
                self.lastInterfaces = kinds
                if changed, path.status == .satisfied, self.wantsConnection, !self.offlineByChoice {
                    self.transport.dropConnection(); self.scheduleReconnect()
                }
            }
        }
        m.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = m
    }

    func appDidEnterBackground() async {
        guard config.disconnectInBackground, wantsConnection, currentCall == nil else { return }
        offlineByChoice = true
        stopPresenceUpdates()
        await transport.unregister()
        registrationState = .offline
    }
    func appWillEnterForeground() async {
        offlineByChoice = false
        guard config.disconnectInBackground, wantsConnection, registrationState == .offline else { return }
        try? await start()
    }

    private func observeAppLifecycle() {
        #if os(iOS)
        let nc = NotificationCenter.default
        lifecycleObservers = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.appDidEnterBackground() } },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.appWillEnterForeground() } },
        ]
        #endif
    }

    /// Fetch the session and register. Throws if the token is rejected or registration fails.
    public func start() async throws {
        wantsConnection = true
        if lifecycleObservers.isEmpty { observeAppLifecycle() }
        watchNetwork()
        registrationState = .connecting
        do {
            try TransportSecurity.check(config.baseURL.absoluteString, secure: "https", insecure: "http",
                                        allowInsecure: config.allowInsecureTransport, what: "baseURL")
        } catch { registrationState = .offline; throw error }
        let s = try await api.fetchSession()
        do {
            try TransportSecurity.check(s.wss, secure: "wss", insecure: "ws",
                                        allowInsecure: config.allowInsecureTransport, what: "the session's signalling URL")
        } catch { registrationState = .offline; throw error }
        self.session = s
        guard s.features.calling || s.features.chat else {
            // Nothing to register for; mirror the reference engine's behaviour.
            registrationState = .offline
            return
        }
        try await transport.register(session: s, forceRelay: config.forceRelay)
    }

    public func stop() async {
        wantsConnection = false
        reconnectTask?.cancel(); reconnectTask = nil
        stopPresenceUpdates()
        await transport.unregister()
        session = nil
        currentCall = nil
        threads.removeAll()
    }

    /// Place a call. Honours the tenant's calling feature flag (FR-MT).
    @discardableResult
    public func dial(_ contact: Contact) async throws -> Call {
        guard features.calling else { throw InCallError.featureDisabled("calling") }
        guard registrationState == .registered else { throw InCallError.notRegistered }
        await api.emitEvent(type: "call.initiating", callId: nil, to: contact.sipUser)
        let callId = try await transport.dial(to: contact.sipUser)
        let call = Call(id: callId, peer: contact, direction: .outgoing, state: .initiating, transport: transport)
        currentCall = call
        return call
    }

    public func thread(with contact: Contact) -> ChatThread {
        if let t = threads[contact.sipUser] { return t }
        let api = self.api, to = contact.sipUser
        let t = ChatThread(peer: contact, transport: transport, queue: { key, text, location in
            try await api.queueMessage(toSip: to, key: key, text: text, location: location)
        }, queueBody: { json in try await api.queueMessage(toSip: to, json: json) })
        threads[contact.sipUser] = t
        return t
    }

    /// Join a 3-way call you were invited to. Ends the current call first if there is one. The person who added
    /// you is already there.
    @discardableResult
    public func joinConference(_ invite: ConferenceInvite) async throws -> Call {
        if let c = currentCall { await c.hangup(); try? await Task.sleep(nanoseconds: 700_000_000) }
        return try await dialConference(invite.room)
    }

    private var pendingConference: String?

    /// Bring `contact` into the current call as a 3-way call (FR-CALL-14), for example a rider adding the support
    /// team. The person you're talking to follows you into the call, `contact` is invited, and you join it. To hand
    /// the call over (a warm transfer), hang up once they're talking: the other two stay connected.
    /// Throws if there's no connected call, or if `contact` isn't online (the current call is then left as it was).
    public func addToCall(_ contact: Contact) async throws {
        guard let call = currentCall, call.state == .connected else { throw InCallError.network("There's no connected call to add them to") }
        let room = try await api.createConference(with: [call.peer.sipUser, contact.sipUser])
        func invite(move: Bool) -> String {
            var o: [String: Any] = ["t": "conf", "room": room, "with": [call.peer.displayName, contact.displayName]]
            if move { o["move"] = true }
            return String(data: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), encoding: .utf8) ?? "{}"
        }
        do { try await transport.sendSignal(to: contact.sipUser, json: invite(move: false)) }   // first: if they're offline, nothing changes
        catch InCallError.network(let r) where ChatThread.peerUnreachable(r) { throw InCallError.network("\(contact.displayName) isn't online") }
        try await transport.sendSignal(to: call.peer.sipUser, json: invite(move: true))
        pendingConference = room   // when this call ends, we dial the room (see transport(callDidChange:))
        await call.hangup()
    }

    private func dialConference(_ room: String) async throws -> Call {
        try await dial(Contact(name: room, sipUser: room, displayName: "3-way call", userType: .agent))
    }

    /// Per-user call history (FR-CALL-08).
    public func callHistory(limit: Int = 50) async throws -> [HistoryEntry] {
        try await api.callHistory(limit: limit)
    }

    // MARK: - Helpers

    private func contact(forSip sipUser: String) -> Contact {
        session?.directory.first { $0.sipUser == sipUser }
            ?? Contact(name: sipUser, sipUser: sipUser, displayName: sipUser, userType: .customer)
    }

    private static func stableDeviceId() -> String {
        let key = "incall.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

// MARK: - Transport callbacks → delegate + event emission

extension InCallClient: SIPTransportEvents {
    func transport(registrationDidChange state: RegistrationState) {
        if state == .offline, wantsConnection, !offlineByChoice { scheduleReconnect() }
        registrationState = state
        if state == .registered && features.chat { Task { await drainHeldMessages() } }   // on every (re)connect
    }

    /// FR-CHAT-03: hand over messages the platform held while this user wasn't connected, then confirm them.
    private func drainHeldMessages() async {
        guard !drainingHeld else { return }
        drainingHeld = true
        defer { drainingHeld = false }
        guard let held = try? await api.pendingMessages() else { return }
        var delivered: [Int64] = []
        for m in held {
            guard let from = m.fromSip else { continue }
            let key = m.key ?? "held:\(m.id)"
            switch m.kind {
            case "text": transport(messageFrom: from, text: m.text ?? "", location: nil, messageId: key)
            case "loc": if let loc = m.location { transport(messageFrom: from, text: nil, location: loc, messageId: key) }
            case "file": if let a = m.attachment { transport(attachmentFrom: from, attachment: a, messageId: key) }
            default: break
            }
            delivered.append(m.id)   // an unknown kind is still confirmed, so it isn't offered forever
        }
        try? await api.ackMessages(delivered)
    }

    func transport(incomingCallFrom sipUser: String, callId: String) {
        let call = Call(id: callId, peer: contact(forSip: sipUser), direction: .incoming,
                        state: .ringing, transport: transport)
        currentCall = call
        notify { $0.client(self, didReceiveIncomingCall: call) }
    }

    func transport(callDidChange state: CallState, callId: String) {
        guard let call = currentCall, call.id == callId else { return }
        let previous = call.state
        call.apply(state: state)
        notify { $0.client(self, callDidChangeState: call) }
        // Mirror lifecycle to the platform for CDRs/reporting (contract §4).
        switch state {
        case .ringing:    Task { await api.emitEvent(type: "call.ringing", callId: callId, to: call.peer.sipUser) }
        case .connected:
            if previous != .onHold { Task { await api.emitEvent(type: "call.connected", callId: callId, to: call.peer.sipUser) } }
        case .ended(let reason):
            Task { await api.emitEvent(type: "call.ended", callId: callId, to: call.peer.sipUser,
                                       payload: ["reason": reason.rawValue, "client": Self.clientInfo]) }
            if currentCall?.id == callId { currentCall = nil }
            // The person we were talking to moved the call into a 3-way call: follow them there.
            if let room = pendingConference {
                pendingConference = nil
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    do { let c = try await dialConference(room); notify { $0.client(self, conferenceDidStart: c) } }
                    catch { notify { $0.client(self, didFail: error as? InCallError ?? .network("conference")) } }
                }
            }
        default: break
        }
    }

    func transport(qualityDidUpdate quality: CallQuality, callId: String) {
        currentCall?.apply(quality: quality)
        notify { $0.client(self, callQualityDidUpdate: quality) }
    }

    func transport(attachmentFrom sipUser: String, attachment: Attachment, messageId: String) {
        let t = thread(with: contact(forSip: sipUser))
        t.appendIncoming(id: messageId, text: nil, location: nil, attachment: attachment)
        if let msg = t.messages.last { notify { $0.client(self, didReceiveMessage: msg, in: t) } }
    }

    /// Upload a photo or file for a chat (FR-CHAT-04); then send it with `ChatThread.sendAttachment`.
    public func uploadAttachment(name: String, type: String, data: Data) async throws -> Attachment {
        try await api.uploadAttachment(name: name, type: type, data: data)
    }

    func transport(messageFrom sipUser: String, text: String?, location: SharedLocation?, messageId: String) {
        let t = thread(with: contact(forSip: sipUser))
        t.appendIncoming(id: messageId, text: text, location: location)
        if let msg = t.messages.last { notify { $0.client(self, didReceiveMessage: msg, in: t) } }
    }

    func transport(messageStatusDidChange messageId: String, status: MessageStatus) {
        for t in threads.values {
            t.update(messageId: messageId, status: status)
            if let msg = t.messages.first(where: { $0.id == messageId }) {
                notify { $0.client(self, messageStatusDidChange: msg) }; return
            }
        }
    }

    func transport(didFail error: InCallError) { notify { $0.client(self, didFail: error) } }

    func transport(conferenceInviteFrom sipUser: String, room: String, move: Bool, with: [String]) {
        if move, currentCall?.peer.sipUser == sipUser { pendingConference = room; return }   // we follow when they hang up
        let from = (session?.peers ?? []).first { $0.sipUser == sipUser } ?? contact(forSip: sipUser)
        notify { $0.client(self, didReceiveConferenceInvite: ConferenceInvite(room: room, from: from, with: with)) }
    }
}

// Device facts sent with call.ended for the call-quality report by OS / app version (FR-REP-06).
extension InCallClient {
    nonisolated static var clientInfo: [String: Any] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let os = "iOS"
        #else
        let os = "macOS"
        #endif
        var info: [String: Any] = ["os": os, "osVersion": "\(v.majorVersion).\(v.minorVersion)"]
        if let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { info["appVersion"] = app }
        return info
    }
}
