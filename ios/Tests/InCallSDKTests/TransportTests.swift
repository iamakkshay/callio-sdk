import XCTest
@testable import InCallSDK

final class TransportTests: XCTestCase {

    // MD5 sanity + the cross-checked RFC-2069 digest vector (verified against the `md5` CLI).
    func testMd5() {
        XCTAssertEqual(DigestAuth.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testDigestResponseNoQop() {
        let ch = DigestAuth.parseChallenge(#"Digest realm="testrealm@host.com", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093""#)!
        XCTAssertEqual(ch.realm, "testrealm@host.com")
        XCTAssertNil(ch.qop)
        let auth = DigestAuth.authorization(username: "Mufasa", password: "Circle Of Life",
                                            method: "REGISTER", uri: "sip:host.com", challenge: ch)
        // HA1=939e..bce9, HA2=4280..2596, response=MD5(HA1:nonce:HA2)
        XCTAssertTrue(auth.contains(#"response="52ad2b6a7cc0537ab3f10c9feabf754d""#), auth)
        XCTAssertTrue(auth.contains(#"username="Mufasa""#))
        XCTAssertTrue(auth.contains("algorithm=MD5"))
    }

    func testDigestResponseWithQop() {
        let ch = DigestAuth.parseChallenge(#"Digest realm="lab", nonce="abc123", qop="auth""#)!
        XCTAssertEqual(ch.qop, "auth")
        let auth = DigestAuth.authorization(username: "1004", password: "secret", method: "INVITE",
                                            uri: "sip:1005@lab", challenge: ch, cnonce: "deadbeef", nc: "00000001")
        // qop=auth form: response = MD5(HA1:nonce:nc:cnonce:auth:HA2)
        let ha1 = DigestAuth.md5Hex("1004:lab:secret")
        let ha2 = DigestAuth.md5Hex("INVITE:sip:1005@lab")
        let expected = DigestAuth.md5Hex("\(ha1):abc123:00000001:deadbeef:auth:\(ha2)")
        XCTAssertTrue(auth.contains("response=\"\(expected)\""), auth)
        XCTAssertTrue(auth.contains("qop=auth"))
        XCTAssertTrue(auth.contains("cnonce=\"deadbeef\""))
    }

    func testParseResponse() {
        let raw = "SIP/2.0 200 OK\r\nVia: SIP/2.0/WS x;branch=z9hG4bK1\r\nCSeq: 2 REGISTER\r\nContact: <sip:1004@host>\r\n\r\n"
        let m = SipMessage.parse(raw)
        XCTAssertEqual(m.statusCode, 200)
        XCTAssertNil(m.method)
        XCTAssertEqual(m.header("cseq"), "2 REGISTER")
        XCTAssertEqual(m.header("Contact"), "<sip:1004@host>")
    }

    func testParseRequestWithBody() {
        let raw = "MESSAGE sip:1005@lab SIP/2.0\r\nFrom: <sip:1004@lab>;tag=t1\r\nContent-Type: application/json\r\n\r\n{\"t\":\"text\",\"text\":\"hi\"}"
        let m = SipMessage.parse(raw)
        XCTAssertEqual(m.method, "MESSAGE")
        XCTAssertNil(m.statusCode)
        XCTAssertEqual(m.body, "{\"t\":\"text\",\"text\":\"hi\"}")
    }

    func testBuildRequestHasContentLength() {
        let out = SipMessage.buildRequest(method: "MESSAGE", requestURI: "sip:1005@lab",
                                          headers: [("To", "<sip:1005@lab>")], body: "hello")
        XCTAssertTrue(out.hasPrefix("MESSAGE sip:1005@lab SIP/2.0\r\n"))
        XCTAssertTrue(out.contains("Content-Length: 5\r\n"))
        XCTAssertTrue(out.hasSuffix("\r\n\r\nhello"))
    }
}
