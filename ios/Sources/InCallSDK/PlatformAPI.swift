import Foundation

/// Thin HTTP client for the platform-api surface the SDK needs (contract §8). Every request carries
/// the tenant JWT as a Bearer token; on a 401 the caller refreshes via the config's tokenProvider and
/// retries. This is fully implemented — only the media transport is stubbed.
actor PlatformAPI {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String
    private var cachedToken: String?

    init(baseURL: URL, tokenProvider: @escaping @Sendable () async throws -> String) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = URLSession(configuration: .ephemeral)
    }

    func refreshToken() async throws -> String {
        let t = try await tokenProvider()
        cachedToken = t
        return t
    }

    private func token() async throws -> String {
        if let t = cachedToken { return t }
        return try await refreshToken()
    }

    // MARK: - Endpoints

    func fetchSession() async throws -> Session {
        try await get("/api/session", as: Session.self)
    }

    func callHistory(limit: Int = 50) async throws -> [HistoryEntry] {
        struct Wrap: Codable { let history: [HistoryEntry] }
        return try await get("/api/history?limit=\(limit)", as: Wrap.self).history
    }

    /// Emit a call/chat/location lifecycle event → CDR + webhook + push dispatch (FR-REP-02).
    func emitEvent(type: String, callId: String?, to: String?, payload: [String: Any] = [:]) async {
        var body: [String: Any] = ["type": type]
        if let callId { body["callId"] = callId }
        if let to { body["to"] = to }
        if !payload.isEmpty { body["payload"] = payload }
        _ = try? await postJSON("/api/events", body: body)
    }

    /// Register this device's APNs VoIP token so the platform can wake the app on an incoming call
    /// (FR-SDK-06 / FR-CALL-03).
    func registerPush(deviceId: String, token: String) async throws {
        _ = try await postJSON("/api/push/register",
                               body: ["deviceId": deviceId, "platform": "apns", "token": token])
    }

    func unregisterPush(deviceId: String) async throws {
        _ = try await postJSON("/api/push/unregister", body: ["deviceId": deviceId])
    }

    /// FR-SDK-05: who of these users (extensions or usernames) is connected now; nil = unknown.
    func presence(_ users: [String]) async throws -> [String: Bool?] {
        struct Row: Decodable { let sipUser: String; let online: Bool? }
        struct Body: Decodable { let presence: [Row] }
        let q = users.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let body = try await get("/api/presence?users=\(q)", as: Body.self)
        return Dictionary(body.presence.map { ($0.sipUser, $0.online) }, uniquingKeysWith: { a, _ in a })
    }

    func uploadDiagnostics(_ summary: [String: Any]) async {
        _ = try? await postJSON("/api/diag", body: ["summary": summary])
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let data = try await send(makeRequest(path, method: "GET"))
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func postJSON(_ path: String, body: [String: Any]) async throws -> Data {
        var req = makeRequest(path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func makeRequest(_ path: String, method: String) -> URLRequest {
        // Concatenate rather than appendingPathComponent so the query string ("?limit=") is kept intact.
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        let url = URL(string: base + (path.hasPrefix("/") ? path : "/" + path)) ?? baseURL
        var req = URLRequest(url: url)
        req.httpMethod = method
        return req
    }

    /// Sends the request with the Bearer token, refreshing once on a 401 (contract §2 token lifecycle).
    private func send(_ request: URLRequest, retriedOn401: Bool = false) async throws -> Data {
        var req = request
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        req.setValue("ios/\(InCallSDKVersion.current)", forHTTPHeaderField: "X-SDK-Version")   // FR-SDK-10
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw InCallError.network(error.localizedDescription) }

        guard let http = resp as? HTTPURLResponse else { throw InCallError.network("no response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401:
            guard !retriedOn401 else { throw InCallError.tokenExpired }
            _ = try await refreshToken()
            return try await send(request, retriedOn401: true)
        default:
            throw InCallError.network("HTTP \(http.statusCode)")
        }
    }
}
