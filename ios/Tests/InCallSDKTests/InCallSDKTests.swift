import XCTest
@testable import InCallSDK

@MainActor
final class InCallSDKTests: XCTestCase {
    func testClientStartsOffline() {
        let config = InCallConfig(baseURL: URL(string: "https://example.test")!) { "token" }
        let client = InCallClient(config: config)
        XCTAssertEqual(client.registrationState, .offline)
        XCTAssertNil(client.currentCall)
    }

    func testIncomingCallPushParses() {
        let payload: [AnyHashable: Any] = [
            "notification": ["type": "incoming_call", "callId": "c1", "tenant": "lab",
                             "from": ["displayName": "Vineet", "userType": "agent"]]
        ]
        let push = PushService.parse(payload)
        XCTAssertEqual(push?.callId, "c1")
        XCTAssertEqual(push?.fromDisplayName, "Vineet")
    }

    // Components like the CallKit bridge observe the client without replacing the app's delegate.
    func testObserversGetEventsAlongsideTheDelegate() {
        final class Rec: InCallClientDelegate { var states: [RegistrationState] = []
            func client(_ c: InCallClient, registrationDidChange s: RegistrationState) { states.append(s) } }
        let client = InCallClient(config: InCallConfig(baseURL: URL(string: "https://example.test")!) { "t" })
        let app = Rec(), bridge = Rec(), gone = Rec()
        client.delegate = app
        client.addObserver(bridge); client.addObserver(bridge); client.addObserver(app); client.addObserver(gone)
        client.removeObserver(gone)
        client.transport(registrationDidChange: .registered)
        XCTAssertEqual(app.states, [.registered], "the delegate hears once, even if also added as an observer")
        XCTAssertEqual(bridge.states, [.registered], "an observer added twice hears once")
        XCTAssertEqual(gone.states, [])
    }

    func testFeaturesDefault() {
        let f = Features()
        XCTAssertTrue(f.calling); XCTAssertFalse(f.recording)
    }
}
