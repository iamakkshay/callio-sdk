// Prebuilt UI (FR-SDK-03): themeable SwiftUI screens for calls and chat on top of InCallSDK. Brand it with an
// InCallTheme; strings follow the device language (English / Arabic, right-to-left) or InCallStrings.
import SwiftUI

public struct InCallTheme {
    public var accent: Color
    public var background: Color
    public var surface: Color
    public var onSurface: Color
    public var secondaryText: Color
    public var danger: Color
    public var success: Color
    public var myBubble: Color
    public var peerBubble: Color
    public var cornerRadius: CGFloat
    public var fontDesign: Font.Design

    public init(accent: Color = Color(red: 0.06, green: 0.62, blue: 0.43),
                background: Color = Color(red: 0.10, green: 0.09, blue: 0.07),
                surface: Color = Color(red: 0.16, green: 0.14, blue: 0.11),
                onSurface: Color = Color(red: 0.95, green: 0.93, blue: 0.89),
                secondaryText: Color = Color(red: 0.70, green: 0.65, blue: 0.58),
                danger: Color = Color(red: 0.86, green: 0.21, blue: 0.21),
                success: Color = Color(red: 0.06, green: 0.62, blue: 0.43),
                myBubble: Color? = nil, peerBubble: Color? = nil,
                cornerRadius: CGFloat = 18, fontDesign: Font.Design = .default) {
        self.accent = accent; self.background = background; self.surface = surface; self.onSurface = onSurface
        self.secondaryText = secondaryText; self.danger = danger; self.success = success
        self.myBubble = myBubble ?? accent; self.peerBubble = peerBubble ?? surface
        self.cornerRadius = cornerRadius; self.fontDesign = fontDesign
    }

    /// The default dark theme (matches the reference web app).
    public static let standard = InCallTheme()
    /// A light theme.
    public static let light = InCallTheme(background: .white, surface: Color(white: 0.95), onSurface: Color(white: 0.1),
                                          secondaryText: Color(white: 0.4))
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = InCallTheme.standard }
private struct StringsKey: EnvironmentKey { static let defaultValue = InCallStrings() }

public extension EnvironmentValues {
    var inCallTheme: InCallTheme { get { self[ThemeKey.self] } set { self[ThemeKey.self] = newValue } }
    var inCallStrings: InCallStrings { get { self[StringsKey.self] } set { self[StringsKey.self] = newValue } }
}

public extension View {
    /// Brand the prebuilt screens.
    func inCallTheme(_ theme: InCallTheme) -> some View { environment(\.inCallTheme, theme) }
    /// Use a fixed language (and its layout direction) instead of the device's.
    func inCallStrings(_ strings: InCallStrings) -> some View {
        environment(\.inCallStrings, strings).environment(\.layoutDirection, strings.isRightToLeft ? .rightToLeft : .leftToRight)
    }
}
