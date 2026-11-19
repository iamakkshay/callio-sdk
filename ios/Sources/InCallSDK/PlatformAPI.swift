import Foundation

/// Thin HTTP client for the platform-api surface the SDK needs (contract §8). Every request carries
/// the tenant JWT as a Bearer token; on a 401 the caller refreshes via the config's tokenProvider and
/// retries. This is fully implemented — only the media transport is stubbed.
actor PlatformAPI {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String
    private var cachedToken: String?

    /// Sent as X-Device-Id on every request: the platform ties each app token to one device.
    private let deviceId: String?

    init(baseURL: URL, tokenProvider: @escaping @Sendable () async throws -> String, deviceId: String? = nil) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.deviceId = deviceId
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

    /// FR-CALL-14: a conference room for these people (extensions); returns the number to dial.
    func createConference(with users: [String]) async throws -> String {
        let data: Data
        do { data = try await postJSON("/api/conferences", body: ["with": users]) }
        catch InCallError.network(let r) where r == "HTTP 503" { throw InCallError.featureDisabled("3-way calls") }
        struct Room: Decodable { let dial: String }
        return try JSONDecoder().decode(Room.self, from: data).dial
    }

    /// FR-CHAT-03: hold a message for someone who isn't connected; the platform delivers it (and wakes them).
    func queueMessage(toSip: String, key: String, text: String?, location: SharedLocation?) async throws {
        var body: [String: Any] = ["key": key]
        if let location {
            body["t"] = "loc"; body["loc"] = ["lat": location.lat, "lng": location.lng, "label": location.label]
        } else {
            body["t"] = "text"; body["text"] = text ?? ""
        }
        _ = try await postJSON("/api/messages", body: ["to": toSip, "body": body])
    }

    /// Hold any chat body (JSON text) for someone who isn't connected.
    func queueMessage(toSip: String, json: String) async throws {
        let body = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [:]
        _ = try await postJSON("/api/messages", body: ["to": toSip, "body": body])
    }

    /// FR-CHAT-04: store a photo or file for a chat; returns the reference to send.
    func uploadAttachment(name: String, type: String, data: Data) async throws -> Attachment {
        struct Wrap: Decodable { let attachment: Attachment }
        let d = try await postJSON("/api/attachments", body: ["name": name, "type": type, "dataBase64": data.base64EncodedString()])
        return try JSONDecoder().decode(Wrap.self, from: d).attachment
    }

    /// Messages held for this user while they weren't connected, oldest first.
    func pendingMessages() async throws -> [PendingMessage] {
        struct Loc: Decodable { let lat: Double; let lng: Double; let label: String? }
        struct Body: Decodable { let t: String?; let key: String?; let text: String?; let loc: Loc?; let attachment: Attachment? }
        struct Row: Decodable { let id: Int64; let fromSip: String?; let body: Body? }
        struct Wrap: Decodable { let messages: [Row] }
        return try await get("/api/messages/pending", as: Wrap.self).messages.map { r in
            let loc = r.body?.loc.map { SharedLocation(lat: $0.lat, lng: $0.lng, label: $0.label ?? "Shared location") }
            let att = r.body?.attachment.flatMap { $0.url.hasPrefix("/api/attachments/") ? $0 : nil }
            return PendingMessage(id: r.id, fromSip: r.fromSip, kind: r.body?.t ?? "", key: r.body?.key, text: r.body?.text, location: loc, attachment: att)
        }
    }

    /// Confirm these held messages arrived, so they aren't handed over again.
    func ackMessages(_ ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await postJSON("/api/messages/ack", body: ["ids": ids])
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
        if let deviceId { req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id") }
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

struct PendingMessage: Sendable {
    let id: Int64
    let fromSip: String?
    let kind: String
    let key: String?
    let text: String?
    let location: SharedLocation?
    let attachment: Attachment?
}
