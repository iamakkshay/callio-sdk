// Call audio routing on iOS (FR-CALL-04): earpiece, speaker or a Bluetooth headset, and notice when the route
// changes underneath the call (headset connected or removed, CarPlay). Wired headsets take over the built-in
// route automatically and are reported as `.earpiece` (the "not speaker, not Bluetooth" route).
#if os(iOS)
import AVFoundation
import UIKit

@MainActor
public final class AudioRouter {
    public static let shared = AudioRouter()

    /// Called on the main actor whenever the output route changes, for any reason.
    public var onChange: ((AudioRoute) -> Void)?
    private var observer: NSObjectProtocol?

    private var session: AVAudioSession { .sharedInstance() }
    private static let bluetoothPorts: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothLE, .bluetoothA2DP]

    /// Two-way voice with Bluetooth (HFP) headsets allowed. CallKit activates the session; without CallKit,
    /// call `activate()` when media starts.
    public func configureForCall() throws {
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        startObserving()
    }
    public func activate() throws { try session.setActive(true) }
    public func deactivate() { try? session.setActive(false, options: .notifyOthersOnDeactivation) }

    /// Where audio is going now.
    public var current: AudioRoute { Self.route(forOutput: session.currentRoute.outputs.first?.portType) }

    /// Routes the user can pick right now: the earpiece only on a phone, Bluetooth only when a headset is connected.
    public var available: [AudioRoute] {
        var r: [AudioRoute] = []
        if UIDevice.current.userInterfaceIdiom == .phone { r.append(.earpiece) }
        r.append(.speaker)
        if bluetoothInput != nil || Self.bluetoothPorts.contains(where: { p in session.currentRoute.outputs.contains { $0.portType == p } }) { r.append(.bluetooth) }
        return r
    }

    public func set(_ route: AudioRoute) throws {
        switch route {
        case .speaker:
            try session.overrideOutputAudioPort(.speaker)
        case .earpiece:
            try session.overrideOutputAudioPort(.none)
            if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) { try session.setPreferredInput(mic) }
        case .bluetooth:
            guard let bt = bluetoothInput else { throw InCallError.mediaFailed("no Bluetooth headset connected") }
            try session.overrideOutputAudioPort(.none)
            try session.setPreferredInput(bt)
        }
    }

    private var bluetoothInput: AVAudioSessionPortDescription? {
        session.availableInputs?.first { Self.bluetoothPorts.contains($0.portType) }
    }

    func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in guard let router = self else { return }; router.onChange?(router.current) }
        }
    }

    nonisolated static func route(forOutput port: AVAudioSession.Port?) -> AudioRoute {
        guard let port else { return .earpiece }
        if port == .builtInSpeaker { return .speaker }
        if bluetoothPorts.contains(port) || port == .carAudio { return .bluetooth }
        return .earpiece
    }
}
#endif
