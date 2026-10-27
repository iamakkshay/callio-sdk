import SwiftUI
import InCallSDK

/// The in-call screen: who, status and duration, quality, and controls (mute, keypad, audio route, hold, end).
/// With CallKit the system shows its own screen on the lock screen; this is the in-app one.
public struct CallScreen: View {
    @ObservedObject var model: CallViewModel
    @Environment(\.inCallTheme) private var theme
    @Environment(\.inCallStrings) private var strings
    @State private var showKeypad = false
    @State private var dialed = ""
    private let onClose: () -> Void

    public init(model: CallViewModel, onClose: @escaping () -> Void = {}) { self.model = model; self.onClose = onClose }

    public var body: some View {
        let peer = model.call?.peer
        let bars = CallPresentation.bars(model.quality)
        VStack(spacing: 18) {
            Spacer(minLength: 24)
            Text(CallPresentation.initials(peer?.displayName ?? ""))
                .font(.system(size: 40, weight: .semibold, design: theme.fontDesign))
                .foregroundColor(theme.onSurface)
                .frame(width: 112, height: 112)
                .background(Circle().fill(theme.surface))
                .accessibilityHidden(true)
            Text(peer?.displayName ?? "")
                .font(.system(.title, design: theme.fontDesign).weight(.semibold))
                .foregroundColor(theme.onSurface)
            Text(CallPresentation.status(model.state, direction: model.call?.direction ?? .outgoing, seconds: model.seconds, strings: strings))
                .font(.system(.body, design: theme.fontDesign).monospacedDigit())
                .foregroundColor(theme.secondaryText)
            if model.state == .connected { QualityBars(bars: bars).accessibilityLabel(CallPresentation.qualityText(bars, strings: strings)) }
            if showKeypad {
                Text(dialed).font(.system(.title2, design: .monospaced)).foregroundColor(theme.onSurface).frame(minHeight: 30)
                Keypad { d in dialed.append(d); Task { await model.sendDTMF(d) } }
            }
            Spacer()
            controls
        }
        .padding(.horizontal, 24).padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .onChange(of: model.state) { s in if case .ended = s { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { onClose() } } }
    }

    @ViewBuilder private var controls: some View {
        if model.state == .ringing && model.call?.direction == .incoming {
            HStack(spacing: 64) {
                RoundButton(symbol: "phone.down.fill", label: strings["decline"], fill: theme.danger) { Task { await model.decline() } }
                RoundButton(symbol: "phone.fill", label: strings["answer"], fill: theme.success) { Task { await model.answer() } }
            }
        } else {
            VStack(spacing: 22) {
                HStack(spacing: 28) {
                    ToggleButton(symbol: model.isMuted ? "mic.slash.fill" : "mic.fill", label: strings[model.isMuted ? "unmute" : "mute"], on: model.isMuted) { Task { await model.toggleMute() } }
                    ToggleButton(symbol: "circle.grid.3x3.fill", label: strings[showKeypad ? "hideKeypad" : "keypad"], on: showKeypad) { showKeypad.toggle() }
                    routeButton
                    ToggleButton(symbol: model.isOnHold ? "play.fill" : "pause.fill", label: strings[model.isOnHold ? "resume" : "hold"], on: model.isOnHold) { Task { await model.toggleHold() } }
                }
                RoundButton(symbol: "phone.down.fill", label: strings["end"], fill: theme.danger) { Task { await model.hangup() } }
            }
        }
    }

    @ViewBuilder private var routeButton: some View {
        let routes = model.availableRoutes
        if routes.count > 2 {
            Menu {
                ForEach(routes, id: \.self) { r in
                    Button { Task { await model.setRoute(r) } } label: { Label(strings[r.rawValue], systemImage: Self.symbol(r)) }
                }
            } label: { ToggleLabel(symbol: Self.symbol(model.route), label: strings["audio"], on: model.route != .earpiece) }
        } else {
            ToggleButton(symbol: "speaker.wave.2.fill", label: strings["speaker"], on: model.route == .speaker) {
                Task { await model.setRoute(model.route == .speaker ? .earpiece : .speaker) }
            }
        }
    }

    static func symbol(_ r: AudioRoute) -> String {
        switch r { case .speaker: return "speaker.wave.2.fill"; case .earpiece: return "iphone"; case .bluetooth: return "headphones" }
    }
}

/// Incoming call inside the app (when CallKit isn't used, or the app is in front).
public struct IncomingCallView: View {
    @ObservedObject var model: CallViewModel
    public init(model: CallViewModel) { self.model = model }
    public var body: some View { CallScreen(model: model) }
}

// MARK: - pieces

struct QualityBars: View {
    let bars: Int
    @Environment(\.inCallTheme) private var theme
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5).fill(i <= bars ? (bars == 1 ? theme.danger : theme.success) : theme.surface)
                    .frame(width: 5, height: CGFloat(5 + i * 4))
            }
        }
        .environment(\.layoutDirection, .leftToRight)   // signal bars don't mirror
    }
}

struct ToggleLabel: View {
    let symbol: String, label: String, on: Bool
    @Environment(\.inCallTheme) private var theme
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22))
                .foregroundColor(on ? theme.background : theme.onSurface)
                .frame(width: 60, height: 60)
                .background(Circle().fill(on ? theme.onSurface : theme.surface))
            Text(label).font(.system(.caption, design: theme.fontDesign)).foregroundColor(theme.secondaryText).lineLimit(1)
        }
        .frame(minWidth: 64)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct ToggleButton: View {
    let symbol: String, label: String, on: Bool, action: () -> Void
    var body: some View { Button(action: action) { ToggleLabel(symbol: symbol, label: label, on: on) }.buttonStyle(.plain) }
}

struct RoundButton: View {
    let symbol: String, label: String, fill: Color, action: () -> Void
    @Environment(\.inCallTheme) private var theme
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 26)).foregroundColor(.white)
                    .frame(width: 72, height: 72).background(Circle().fill(fill))
                Text(label).font(.system(.caption, design: theme.fontDesign)).foregroundColor(theme.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct Keypad: View {
    let onKey: (String) -> Void
    @Environment(\.inCallTheme) private var theme
    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]
    var body: some View {
        VStack(spacing: 12) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 22) {
                    ForEach(row, id: \.self) { k in
                        Button { onKey(k) } label: {
                            Text(k).font(.system(size: 28, weight: .medium, design: .rounded)).foregroundColor(theme.onSurface)
                                .frame(width: 64, height: 64).background(Circle().fill(theme.surface))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)   // a keypad reads the same in Arabic
    }
}
