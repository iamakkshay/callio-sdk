import SwiftUI
import Combine
import InCallSDK

/// Messages with one contact for the prebuilt chat screen.
@MainActor
public final class ChatViewModel: ObservableObject, InCallClientDelegate {
    @Published public private(set) var messages: [Message] = []
    @Published public var draft = "" { didSet { typingChanged() } }
    public let thread: ChatThread
    private let client: InCallClient
    private var typingSent = false

    public init(client: InCallClient, contact: Contact) {
        self.client = client
        thread = client.thread(with: contact)
        messages = thread.messages
        client.addObserver(self)
    }

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        _ = try? await thread.send(text: text)
        messages = thread.messages
    }

    public func share(_ location: SharedLocation) async {
        _ = try? await thread.sendLocation(location)
        messages = thread.messages
    }

    private func typingChanged() {
        let typing = !draft.isEmpty
        guard typing != typingSent else { return }
        typingSent = typing
        Task { await thread.setTyping(typing) }
    }

    public func client(_ client: InCallClient, didReceiveMessage message: Message, in thread: ChatThread) {
        if thread === self.thread { messages = thread.messages }
    }
    public func client(_ client: InCallClient, messageStatusDidChange message: Message) { messages = thread.messages }
}

/// The chat screen: bubbles, location cards, a composer. `onShareLocation` lets the host app get the location
/// its own way (permission prompt, picker) and hand it back.
public struct ChatView: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.inCallTheme) private var theme
    @Environment(\.inCallStrings) private var strings
    private let onShareLocation: (() async -> SharedLocation?)?
    private let onOpenLocation: ((SharedLocation) -> Void)?

    public init(model: ChatViewModel, onShareLocation: (() async -> SharedLocation?)? = nil, onOpenLocation: ((SharedLocation) -> Void)? = nil) {
        self.model = model; self.onShareLocation = onShareLocation; self.onOpenLocation = onOpenLocation
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.messages) { m in ChatBubble(message: m, onOpenLocation: onOpenLocation).id(m.id) }
                    }
                    .padding(12)
                }
                .onChange(of: model.messages.count) { _ in if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            composer
        }
        .background(theme.background.ignoresSafeArea())
    }

    private var composer: some View {
        HStack(spacing: 10) {
            if let share = onShareLocation {
                Button { Task { if let loc = await share() { await model.share(loc) } } } label: {
                    Image(systemName: "location.fill").foregroundColor(theme.accent).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(strings["shareLocation"])
            }
            TextField(strings["message"], text: $model.draft)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(theme.surface))
                .foregroundColor(theme.onSurface)
                .onSubmit { Task { await model.send() } }
            Button { Task { await model.send() } } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    .foregroundColor(model.draft.isEmpty ? theme.secondaryText : theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(model.draft.isEmpty)
            .accessibilityLabel(strings["send"])
        }
        .padding(10)
    }

}

/// One message: text, or a location card that opens the host's map.
public struct ChatBubble: View {
    let message: Message
    let onOpenLocation: ((SharedLocation) -> Void)?
    @Environment(\.inCallTheme) private var theme
    @Environment(\.inCallStrings) private var strings

    public init(message: Message, onOpenLocation: ((SharedLocation) -> Void)? = nil) { self.message = message; self.onOpenLocation = onOpenLocation }

    public var body: some View {
        let mine = message.from == .me
        HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if let loc = message.location {
                    Button { onOpenLocation?(loc) } label: {
                        Label(loc.label.isEmpty ? strings["location"] : loc.label, systemImage: "mappin.and.ellipse")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(strings["openMap"])
                } else {
                    Text(message.text ?? "")
                }
                if mine && message.status == .failed { Text(strings["failed"]).font(.caption2).foregroundColor(theme.danger) }
            }
            .font(.system(.body, design: theme.fontDesign))
            .foregroundColor(mine ? .white : theme.onSurface)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(mine ? theme.myBubble : theme.peerBubble))
            if !mine { Spacer(minLength: 48) }
        }
    }
}
