import Foundation
import Combine
import InCallSDK

/// Live state of the current call for the prebuilt screens. Observes the client without taking its delegate.
@MainActor
public final class CallViewModel: ObservableObject, InCallClientDelegate {
    @Published public private(set) var call: Call?
    @Published public private(set) var state: CallState = .ended(.ended)
    @Published public private(set) var seconds = 0
    @Published public private(set) var isMuted = false
    @Published public private(set) var isOnHold = false
    @Published public private(set) var quality: CallQuality?
    @Published public private(set) var route: AudioRoute = .earpiece
    @Published public var lastError: String?

    public let client: InCallClient
    private var connectedAt: Date?
    private var timer: Timer?

    public init(client: InCallClient) {
        self.client = client
        client.addObserver(self)
        if let c = client.currentCall { attach(c) }
        #if os(iOS)
        route = client.audio.current
        #endif
    }

    public var availableRoutes: [AudioRoute] {
        #if os(iOS)
        return client.audio.available
        #else
        return [.speaker]
        #endif
    }

    private func attach(_ c: Call) {
        call = c; state = c.state; isMuted = c.isMuted; isOnHold = c.isOnHold
        if c.state == .connected { startClock() }
    }

    private func startClock() {
        if connectedAt == nil { connectedAt = Date() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in guard let model = self, let t = model.connectedAt else { return }; model.seconds = Int(Date().timeIntervalSince(t)) }
        }
    }

    // MARK: actions
    public func toggleMute() async { guard let c = call else { return }; await c.setMuted(!isMuted); isMuted = c.isMuted }
    public func toggleHold() async { guard let c = call else { return }; await c.setHold(!isOnHold); isOnHold = c.isOnHold }
    public func setRoute(_ r: AudioRoute) async { await call?.setAudioRoute(r) }
    public func sendDTMF(_ tone: String) async { await call?.sendDTMF(tone) }
    public func hangup() async { await call?.hangup() }
    public func answer() async { do { try await call?.answer() } catch { lastError = "\(error)" } }
    public func decline() async { await call?.decline() }

    // MARK: InCallClientDelegate
    public func client(_ client: InCallClient, didReceiveIncomingCall call: Call) { connectedAt = nil; seconds = 0; attach(call) }
    public func client(_ client: InCallClient, callDidChangeState call: Call) {
        if self.call?.id != call.id { connectedAt = nil; seconds = 0; self.call = call }
        state = call.state
        switch call.state {
        case .connected: startClock()
        case .ended: timer?.invalidate(); timer = nil
        default: break
        }
    }
    public func client(_ client: InCallClient, callQualityDidUpdate quality: CallQuality) { self.quality = quality }
    public func client(_ client: InCallClient, audioRouteDidChange route: AudioRoute) { self.route = route }
    public func client(_ client: InCallClient, didFail error: InCallError) { lastError = "\(error)" }
}
