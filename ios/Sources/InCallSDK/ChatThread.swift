import Foundation

/// A 1:1 chat with a contact (FR-CHAT-01/02). Messages are delivered over the same transport as calls
/// (SIP MESSAGE in the reference engine). Obtain one via `InCallClient.thread(with:)`.
@MainActor
public final class ChatThread {
    public let peer: Contact
    public private(set) var messages: [Message] = []

    private weak var transport: (any SIPTransport)?

    init(peer: Contact, transport: any SIPTransport) {
        self.peer = peer; self.transport = transport
    }

    @discardableResult
    public func send(text: String) async throws -> Message {
        let id = try await transport?.sendMessage(to: peer.sipUser, text: text, location: nil) ?? UUID().uuidString
        let msg = Message(id: id, from: .me, text: text, location: nil, status: .sending)
        messages.append(msg)
        return msg
    }

    @discardableResult
    public func sendLocation(_ location: SharedLocation) async throws -> Message {
        let id = try await transport?.sendMessage(to: peer.sipUser, text: nil, location: location) ?? UUID().uuidString
        let msg = Message(id: id, from: .me, text: nil, location: location, status: .sending)
        messages.append(msg)
        return msg
    }

    public func setTyping(_ typing: Bool) async { await transport?.setTyping(typing, to: peer.sipUser) }

    // Updated by InCallClient from transport callbacks.
    func appendIncoming(id: String, text: String?, location: SharedLocation?) {
        messages.append(Message(id: id, from: .peer, text: text, location: location, status: .delivered))
    }
    func update(messageId: String, status: MessageStatus) {
        if let i = messages.firstIndex(where: { $0.id == messageId }) { messages[i].status = status }
    }
}
