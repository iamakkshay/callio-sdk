import Foundation

/// A 1:1 chat with a contact (FR-CHAT-01/02). Messages are delivered over the same transport as calls
/// (SIP MESSAGE in the reference engine). Obtain one via `InCallClient.thread(with:)`.
@MainActor
public final class ChatThread {
    public let peer: Contact
    public private(set) var messages: [Message] = []

    private weak var transport: (any SIPTransport)?
    /// Hands a message to the platform when the peer isn't connected (FR-CHAT-03): (key, text, location).
    private let queue: (@Sendable (String, String?, SharedLocation?) async throws -> Void)?

    /// Hands any chat body (JSON) to the platform when the peer isn't connected.
    private let queueBody: (@Sendable (String) async throws -> Void)?

    init(peer: Contact, transport: any SIPTransport, queue: (@Sendable (String, String?, SharedLocation?) async throws -> Void)? = nil,
         queueBody: (@Sendable (String) async throws -> Void)? = nil) {
        self.peer = peer; self.transport = transport; self.queue = queue; self.queueBody = queueBody
    }

    /// Send a photo or file already uploaded with `InCallClient.uploadAttachment`. Held for the peer if they're offline.
    @discardableResult
    public func sendAttachment(_ attachment: Attachment) async throws -> Message {
        let id = "me:" + String(UUID().uuidString.prefix(10)).lowercased()
        let body: [String: Any] = ["key": id, "t": "file", "attachment": attachment.json]
        let json = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? "{}"
        var msg = Message(id: id, from: .me, text: nil, location: nil, status: .sending, attachment: attachment)
        do {
            guard let transport else { throw InCallError.notRegistered }
            try await transport.sendSignal(to: peer.sipUser, json: json)
        } catch let InCallError.network(reason) where queueBody != nil && Self.peerUnreachable(reason) {
            try await queueBody?(json)
            msg.status = .queued
        }
        messages.append(msg)
        return msg
    }

    /// Sends now if the peer is connected; otherwise the platform holds it (`.queued`) until they are.
    @discardableResult
    public func send(text: String) async throws -> Message { try await deliver(text: text, location: nil) }

    @discardableResult
    public func sendLocation(_ location: SharedLocation) async throws -> Message { try await deliver(text: nil, location: location) }

    private func deliver(text: String?, location: SharedLocation?) async throws -> Message {
        var msg: Message
        do {
            let id = try await transport?.sendMessage(to: peer.sipUser, text: text, location: location) ?? UUID().uuidString
            msg = Message(id: id, from: .me, text: text, location: location, status: .sending)
        } catch let InCallError.network(reason) where queue != nil && Self.peerUnreachable(reason) {
            let id = "me:" + String(UUID().uuidString.prefix(10)).lowercased()
            try await queue?(id, text, location)
            msg = Message(id: id, from: .me, text: text, location: location, status: .queued)
        }
        messages.append(msg)
        return msg
    }

    /// 480 / 404 / 408: nobody to deliver to right now (not connected, or the connection went quiet).
    nonisolated static func peerUnreachable(_ reason: String) -> Bool {
        reason.range(of: #"\((480|404|408)\)"#, options: .regularExpression) != nil
    }

    public func setTyping(_ typing: Bool) async { await transport?.setTyping(typing, to: peer.sipUser) }

    // Updated by InCallClient from transport callbacks.
    func appendIncoming(id: String, text: String?, location: SharedLocation?, attachment: Attachment? = nil) {
        messages.append(Message(id: id, from: .peer, text: text, location: location, status: .delivered, attachment: attachment))
    }
    func update(messageId: String, status: MessageStatus) {
        if let i = messages.firstIndex(where: { $0.id == messageId }) { messages[i].status = status }
    }
}
