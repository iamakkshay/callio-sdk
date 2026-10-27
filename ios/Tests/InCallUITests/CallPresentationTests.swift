import XCTest
import InCallSDK
@testable import InCallUI

final class CallPresentationTests: XCTestCase {
    let en = InCallStrings(language: .en), ar = InCallStrings(language: .ar)

    func testInitials() {
        XCTAssertEqual(CallPresentation.initials("Akshay Kumar"), "AK")
        XCTAssertEqual(CallPresentation.initials("sarah"), "S")
        XCTAssertEqual(CallPresentation.initials("1002"), "?")
        XCTAssertEqual(CallPresentation.initials("فاطمة الزهراء"), "فا")
    }

    func testDurations() {
        XCTAssertEqual(CallPresentation.duration(7), "0:07")
        XCTAssertEqual(CallPresentation.duration(754), "12:34")
        XCTAssertEqual(CallPresentation.duration(3723), "1:02:03")
    }

    func testStatusLines() {
        XCTAssertEqual(CallPresentation.status(.ringing, direction: .incoming, seconds: 0, strings: en), "Incoming call")
        XCTAssertEqual(CallPresentation.status(.ringing, direction: .outgoing, seconds: 0, strings: en), "Ringing…")
        XCTAssertEqual(CallPresentation.status(.connected, direction: .outgoing, seconds: 65, strings: en), "1:05")
        XCTAssertEqual(CallPresentation.status(.ended(.noAnswer), direction: .outgoing, seconds: 0, strings: en), "No answer")
        XCTAssertEqual(CallPresentation.status(.ended(.busy), direction: .outgoing, seconds: 0, strings: ar), "مشغول")
    }

    func testStrings() {
        XCTAssertTrue(ar.isRightToLeft)
        XCTAssertEqual(InCallStrings(language: .en, overrides: ["end": "Hang up"])["end"], "Hang up")
    }

    func testQualityBars() {
        XCTAssertEqual(CallPresentation.bars(nil), 3)
        XCTAssertEqual(CallPresentation.bars(CallQuality(rttMs: 80, jitterMs: 5, lossPct: 0, mos: 4.3)), 3)
        XCTAssertEqual(CallPresentation.bars(CallQuality(rttMs: 300, jitterMs: 20, lossPct: 1)), 2)
        XCTAssertEqual(CallPresentation.bars(CallQuality(rttMs: 900, jitterMs: 40, lossPct: 12)), 0)
    }
}
