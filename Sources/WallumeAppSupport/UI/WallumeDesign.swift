import AppKit
import SwiftUI

public func wallumeLocalized(_ key: String) -> String {
    let languageName = UserDefaults.standard.string(forKey: "wallume.language") ?? WallumeAppLanguage.chinese.rawValue
    guard let stringsPath = Bundle.module.path(
        forResource: "Localizable",
        ofType: "strings",
        inDirectory: nil,
        forLocalization: languageName
    ), let strings = NSDictionary(contentsOfFile: stringsPath) as? [String: String] else {
        return key
    }
    return strings[key] ?? key
}

/// Formats a localized string with the currently selected in-app language.
/// SwiftUI's `LocalizedStringKey` resolves through the host bundle, while this
/// package owns its strings in `Bundle.module`; keeping formatting here makes
/// dynamic copy follow the same language switch as static copy.
public func wallumeLocalized(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: wallumeLocalized(format), locale: WallumeAppLanguage.current.locale, arguments: arguments)
}

/// Use for visible static copy in this package. It deliberately takes a
/// `String`, rather than a `LocalizedStringKey`, so the in-app language picker
/// always resolves against `Bundle.module`.
public func wallumeText(_ key: String) -> Text {
    Text(wallumeLocalized(key))
}

public enum WallumeTheme: String, CaseIterable, Identifiable {
    case nocturne
    case dawn
    case ember
    case system

    public var id: String { rawValue }

    /// Keeps the visual preference stable for people upgrading from the first
    /// exploration themes.
    public static func fromStoredValue(_ rawValue: String) -> Self {
        switch rawValue {
        case "tide": .nocturne
        case "grove": .dawn
        case "graphite": .system
        case WallumeTheme.ember.rawValue: .nocturne
        default: Self(rawValue: rawValue) ?? .nocturne
        }
    }

    public var title: String {
        switch self {
        case .nocturne: wallumeLocalized("夜幕")
        case .dawn: wallumeLocalized("晨雾")
        case .ember: wallumeLocalized("余烬")
        case .system: wallumeLocalized("跟随系统")
        }
    }

    public var detail: String {
        switch self {
        case .nocturne: wallumeLocalized("沉浸式幕布与珊瑚强调，让画面成为焦点。")
        case .dawn: wallumeLocalized("暖白表面与珊瑚强调，适合明亮桌面。")
        case .ember: wallumeLocalized("在当前 macOS 外观中加入温暖的余烬色调。")
        case .system: wallumeLocalized("完全跟随 macOS 的浅色与深色外观。")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .nocturne: .dark
        case .dawn: .light
        case .ember, .system: nil
        }
    }
}

public struct WallumeThemePalette {
    public let canvas: [Color]
    public let panel: Color
    public let panelRaised: Color
    public let line: Color
    public let accent: Color

    public static func resolve(_ theme: WallumeTheme, scheme: ColorScheme) -> Self {
        let isDark = scheme == .dark
        switch theme {
        case .nocturne:
            return .init(
                canvas: [WallumeDesign.canvas, WallumeDesign.canvas],
                panel: WallumeDesign.surface1,
                panelRaised: WallumeDesign.surface2,
                line: WallumeDesign.line, accent: WallumeDesign.accent
            )
        case .dawn:
            return .init(
                canvas: [Color(red: 0.92, green: 0.95, blue: 0.93), Color(red: 0.97, green: 0.98, blue: 0.95)],
                panel: Color(red: 0.96, green: 0.97, blue: 0.94),
                panelRaised: .white.opacity(0.78),
                line: .black.opacity(0.10), accent: WallumeDesign.accent
            )
        case .ember:
            return .init(
                canvas: isDark ? [Color(red: 0.13, green: 0.055, blue: 0.055), Color(red: 0.12, green: 0.08, blue: 0.04)] : [Color(red: 1.0, green: 0.94, blue: 0.91), Color(red: 1.0, green: 0.97, blue: 0.87)],
                panel: isDark ? Color(red: 0.17, green: 0.07, blue: 0.06) : Color(red: 1.0, green: 0.96, blue: 0.91),
                panelRaised: isDark ? Color(red: 0.23, green: 0.10, blue: 0.07) : .white.opacity(0.7),
                line: isDark ? .white.opacity(0.12) : .black.opacity(0.10), accent: Color(red: 0.82, green: 0.28, blue: 0.16)
            )
        case .system:
            return .init(
                canvas: isDark ? [Color(red: 0.055, green: 0.065, blue: 0.08), Color(red: 0.09, green: 0.1, blue: 0.12)] : [Color(red: 0.94, green: 0.95, blue: 0.97), Color(red: 0.98, green: 0.98, blue: 0.99)],
                panel: isDark ? Color(red: 0.08, green: 0.09, blue: 0.11) : .white.opacity(0.8),
                panelRaised: isDark ? Color(red: 0.12, green: 0.13, blue: 0.16) : .white,
                line: isDark ? .white.opacity(0.12) : .black.opacity(0.10), accent: WallumeDesign.accent
            )
        }
    }
}

public enum WallumeAppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    public static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "wallume.language") ?? "") ?? .chinese
    }

    public var title: String {
        switch self {
        case .chinese: "中文"
        case .english: "English"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

/// Shared presentation primitives. These keep the feature pages visually coherent while
/// leaving all feature state and actions in their existing stores.
public enum WallumeDesign {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    public static let canvas = adaptive(
        light: NSColor(srgbRed: 0.961, green: 0.957, blue: 0.945, alpha: 1),
        dark: NSColor(srgbRed: 0.035, green: 0.035, blue: 0.031, alpha: 1)
    )
    public static let surface1 = adaptive(
        light: NSColor(srgbRed: 0.937, green: 0.929, blue: 0.914, alpha: 1),
        dark: NSColor(srgbRed: 0.067, green: 0.067, blue: 0.059, alpha: 1)
    )
    public static let surface2 = adaptive(
        light: .white,
        dark: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.078, alpha: 1)
    )
    public static let surface3 = adaptive(
        light: NSColor(srgbRed: 0.91, green: 0.902, blue: 0.878, alpha: 1),
        dark: NSColor(srgbRed: 0.137, green: 0.133, blue: 0.118, alpha: 1)
    )
    public static let inset = adaptive(
        light: NSColor(srgbRed: 0.922, green: 0.914, blue: 0.894, alpha: 1),
        dark: NSColor(srgbRed: 0.071, green: 0.071, blue: 0.063, alpha: 1)
    )
    public static let accent = adaptive(
        light: NSColor(srgbRed: 0.72, green: 0.27, blue: 0.20, alpha: 1),
        dark: NSColor(srgbRed: 0.937, green: 0.431, blue: 0.329, alpha: 1)
    )
    public static let warmAccent = accent
    public static let success = adaptive(
        light: NSColor(srgbRed: 0.196, green: 0.471, blue: 0.314, alpha: 1),
        dark: NSColor(srgbRed: 0.412, green: 0.725, blue: 0.541, alpha: 1)
    )
    public static let warning = adaptive(
        light: NSColor(srgbRed: 0.616, green: 0.392, blue: 0.161, alpha: 1),
        dark: NSColor(srgbRed: 0.831, green: 0.604, blue: 0.325, alpha: 1)
    )
    public static let destructive = adaptive(
        light: NSColor(srgbRed: 0.702, green: 0.306, blue: 0.271, alpha: 1),
        dark: NSColor(srgbRed: 0.859, green: 0.427, blue: 0.38, alpha: 1)
    )
    public static let line = Color.primary.opacity(0.085)
    public static let lineStrong = Color.primary.opacity(0.14)
    public static let ink = Color(nsColor: .labelColor)
    public static let motion = Animation.easeOut(duration: 0.18)
    public static let smallCornerRadius: CGFloat = 6
    public static let cardCornerRadius: CGFloat = 10
    public static let largeCornerRadius: CGFloat = 16
    public static let contentWidth: CGFloat = 1120
    public static let sidebarWidth: CGFloat = 76
    public static let toolbarHeight: CGFloat = 62
}

public struct WallumeMark: View {
    private let size: CGFloat

    public init(size: CGFloat = 28) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(WallumeDesign.surface1)
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .stroke(WallumeDesign.accent, lineWidth: size * 0.075)
                .padding(size * 0.18)
            WaveMark()
                .stroke(.white.opacity(0.78), style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .padding(size * 0.09)
            Circle()
                .fill(WallumeDesign.warmAccent)
                .frame(width: size * 0.13, height: size * 0.13)
                .offset(x: size * 0.22, y: -size * 0.22)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Wallume")
    }
}

private struct WaveMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.66))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * 0.4),
            control1: CGPoint(x: rect.width * 0.28, y: rect.height * 0.18),
            control2: CGPoint(x: rect.width * 0.65, y: rect.height * 0.95)
        )
        return path
    }
}

public struct WallumePageHeader<Trailing: View>: View {
    private let title: String
    private let subtitle: String
    private let trailing: Trailing

    public init(
        _ title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(wallumeLocalized(title)).font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(wallumeLocalized(subtitle)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

public struct WallumeStatusBadge: View {
    private let title: String
    private let systemImage: String
    private let tint: Color

    public init(_ title: String, systemImage: String, tint: Color = WallumeDesign.accent) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        Label(wallumeLocalized(title), systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A persistent connection between the selected library media and the desktop
/// it is currently animating. The gallery owns the action; this component only
/// presents the shared playback state.
public struct WallumeNowPlayingRail: View {
    private let mediaName: String
    private let displayName: String

    public init(mediaName: String, displayName: String) {
        self.mediaName = mediaName
        self.displayName = displayName
    }

    public var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(WallumeDesign.success)
                .frame(width: 7, height: 7)
                .shadow(color: WallumeDesign.success.opacity(0.45), radius: 4)
            Text(wallumeLocalized("正在播放"))
                .font(.caption.weight(.semibold))
            Text("\(mediaName) · \(displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "display")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WallumeDesign.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(WallumeDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
    }
}

public extension View {
    func wallumePageBackground() -> some View {
        modifier(WallumeLanguageSurface())
            .modifier(WallumeThemeSurface())
    }

    func wallumeCard() -> some View {
        modifier(WallumeCardSurface())
    }

    func wallumePanel() -> some View {
        padding(20)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
    }

    func wallumeInteractiveSurface() -> some View {
        modifier(WallumeInteractiveSurface())
    }
}

private struct WallumeLanguageSurface: ViewModifier {
    @AppStorage("wallume.language") private var languageName = WallumeAppLanguage.chinese.rawValue

    func body(content: Content) -> some View {
        content.environment(\.locale, WallumeAppLanguage(rawValue: languageName)?.locale ?? WallumeAppLanguage.chinese.locale)
    }
}

private struct WallumeThemeSurface: ViewModifier {
    @AppStorage("wallume.theme") private var themeName = WallumeTheme.nocturne.rawValue
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let theme = WallumeTheme.fromStoredValue(themeName)
        let palette = WallumeThemePalette.resolve(theme, scheme: colorScheme)
        content
            .preferredColorScheme(theme.preferredColorScheme)
            .background(palette.canvas[0].ignoresSafeArea())
            .tint(palette.accent)
    }

}

private struct WallumeCardSurface: ViewModifier {
    @AppStorage("wallume.theme") private var themeName = WallumeTheme.nocturne.rawValue
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = WallumeThemePalette.resolve(WallumeTheme.fromStoredValue(themeName), scheme: colorScheme)
        content
            .padding(16)
            .background(palette.panelRaised, in: RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous).strokeBorder(palette.line) }
    }
}

private struct WallumeInteractiveSurface: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.006 : 1)
            .brightness(isHovered ? 0.025 : 0)
            .animation(WallumeDesign.motion, value: isHovered)
            .onHover { isHovered = $0 }
    }
}
