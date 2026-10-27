import Foundation

/// Minimal SIP message model — parse a received message and build a request. SIP is a line-based text
/// protocol (RFC 3261); over WebSocket the body of each WS text frame is one SIP message. Pure logic,
/// unit-tested; no WebRTC.
struct SipMessage {
    let startLine: String                 // request line or status line
    let headers: [(name: String, value: String)]
    let body: String

    /// For a response: the status code (e.g. 200, 401, 180). nil for a request.
    var statusCode: Int? {
        guard startLine.hasPrefix("SIP/2.0") else { return nil }
        let parts = startLine.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }

    /// For a request: the method (REGISTER, INVITE, …). nil for a response.
    var method: String? {
        startLine.hasPrefix("SIP/2.0") ? nil : String(startLine.split(separator: " ").first ?? "")
    }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func parse(_ raw: String) -> SipMessage {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let split = normalized.range(of: "\n\n")
        let head = split.map { String(normalized[..<$0.lowerBound]) } ?? normalized
        let body = split.map { String(normalized[$0.upperBound...]) } ?? ""
        var lines = head.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let startLine = lines.isEmpty ? "" : lines.removeFirst()
        let headers: [(String, String)] = lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, value)
        }
        return SipMessage(startLine: startLine, headers: headers, body: body)
    }

    /// Serialize a request from a method, request-URI, ordered headers and an optional body.
    static func buildRequest(method: String, requestURI: String,
                             headers: [(name: String, value: String)], body: String = "") -> String {
        var out = "\(method) \(requestURI) SIP/2.0\r\n"
        for h in headers { out += "\(h.name): \(h.value)\r\n" }
        out += "Content-Length: \(body.utf8.count)\r\n\r\n"
        out += body
        return out
    }

    /// Serialize a response (e.g. 200 OK) from a status line + headers + body.
    static func buildResponse(status: Int, reason: String,
                              headers: [(name: String, value: String)], body: String = "") -> String {
        var out = "SIP/2.0 \(status) \(reason)\r\n"
        for h in headers { out += "\(h.name): \(h.value)\r\n" }
        out += "Content-Length: \(body.utf8.count)\r\n\r\n"
        out += body
        return out
    }
}
