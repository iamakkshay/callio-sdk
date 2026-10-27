import Foundation
import CryptoKit

/// SIP digest authentication (RFC 2617 / RFC 3261, MD5). Builds the `Authorization` /
/// `Proxy-Authorization` header value in response to a `WWW-Authenticate` / `Proxy-Authenticate`
/// challenge — exactly what Kamailio's `pv_auth_check` expects for REGISTER and INVITE. This is pure
/// protocol logic (no WebRTC), fully unit-tested.
enum DigestAuth {
    static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    struct Challenge: Equatable {
        let realm: String
        let nonce: String
        var qop: String? = nil
        var opaque: String? = nil
        var algorithm: String? = nil
    }

    /// Parse a `Digest realm="...", nonce="...", qop="auth", ...` challenge header.
    static func parseChallenge(_ header: String) -> Challenge? {
        let params = parseParams(header.replacingOccurrences(of: "Digest ", with: "", options: .caseInsensitive))
        guard let realm = params["realm"], let nonce = params["nonce"] else { return nil }
        return Challenge(realm: realm, nonce: nonce, qop: params["qop"], opaque: params["opaque"], algorithm: params["algorithm"])
    }

    /// Build the Authorization header value. Uses qop=auth with cnonce/nc when the challenge offers it,
    /// else the RFC 2069 form.
    static func authorization(username: String, password: String, method: String, uri: String,
                              challenge: Challenge, cnonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                              nc: String = "00000001") -> String {
        let ha1 = md5Hex("\(username):\(challenge.realm):\(password)")
        let ha2 = md5Hex("\(method):\(uri)")
        var fields = ["username=\"\(username)\"", "realm=\"\(challenge.realm)\"",
                      "nonce=\"\(challenge.nonce)\"", "uri=\"\(uri)\"", "algorithm=MD5"]
        let response: String
        if let qop = challenge.qop, qop.contains("auth") {
            response = md5Hex("\(ha1):\(challenge.nonce):\(nc):\(cnonce):auth:\(ha2)")
            fields += ["qop=auth", "nc=\(nc)", "cnonce=\"\(cnonce)\""]
        } else {
            response = md5Hex("\(ha1):\(challenge.nonce):\(ha2)")
        }
        fields.append("response=\"\(response)\"")
        if let opaque = challenge.opaque { fields.append("opaque=\"\(opaque)\"") }
        return "Digest " + fields.joined(separator: ", ")
    }

    /// Split `a="x", b=y, c="z"` honouring quotes.
    static func parseParams(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = "", val = "", inKey = true, inQuotes = false
        func commit() {
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k.lowercased()] = val.trimmingCharacters(in: .whitespaces) }
            key = ""; val = ""; inKey = true
        }
        for ch in s {
            switch ch {
            case "\"": inQuotes.toggle()
            case "=" where inKey && !inQuotes: inKey = false
            case "," where !inQuotes: commit()
            default: if inKey { key.append(ch) } else { val.append(ch) }
            }
        }
        commit()
        return out
    }
}
