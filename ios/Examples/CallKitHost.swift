// Host-app glue for the native call experience (FR-CALL-02/03). CallKit, PushKit and the audio session are in the
// SDK (InCallCallKit, AudioRouter); the host app turns on the capabilities and creates the bridge once.
//
// Xcode: Signing & Capabilities → Push Notifications, Background Modes → Voice over IP (and Audio).
// Info.plist: NSMicrophoneUsageDescription.
#if canImport(CallKit) && os(iOS)
import UIKit
import InCallSDK

@MainActor
final class CallSetup {
    let client: InCallClient
    let callKit: InCallCallKit

    init(client: InCallClient) {
        self.client = client
        callKit = InCallCallKit(client: client, options: .init(iconTemplateImageData: UIImage(named: "CallIcon")?.pngData()))
        callKit.registerForVoIPPushes()   // the VoIP token is registered with the platform automatically
    }

    func call(_ contact: Contact) async throws { try await callKit.startCall(to: contact) }
    func speaker(_ on: Bool) throws { try client.audio.set(on ? .speaker : .earpiece) }
}
#endif
