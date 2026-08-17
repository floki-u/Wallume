import AppKit
import SwiftUI

public enum WallumeTheme: String, CaseIterable, Identifiable {
    case tide
    case grove
    case ember
    case graphite

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tide: "潮汐"
        case .grove: "林地"
        case .ember: "余烬"
        case .graphite: "石墨"
        }
    }
}

/// Shared presentation primitives. These keep the feature pages visually coherent while
/// leaving all feature state and actions in their existing stores.
public enum WallumeDesign {
    public static let accent = Color(red: 0.0, green: 0.55, blue: 0.52)
    public static let warmAccent = Color(red: 0.9, green: 0.29, blue: 0.22)
    public static let ink = Color(nsColor: .labelColor)
    public static let motion = Animation.spring(response: 0.42, dampingFraction: 0.82)
    public static let cardCornerRadius: CGFloat = 8
    public static let contentWidth: CGFloat = 1120
}

public struct WallumeMark: View {
    private let size: CGFloat

    public init(size: CGFloat = 28) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Color(red: 0.08, green: 0.1, blue: 0.12))
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: size * 0.075)
                .padding(size * 0.18)
            WaveMark()
                .stroke(WallumeDesign.accent, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .padding(size * 0.09)
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
                Text(title).font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
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
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

public extension View {
    func wallumePageBackground() -> some View {
        modifier(WallumeThemeSurface())
    }

    func wallumeCard() -> some View {
        padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1))
            }
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

private struct WallumeThemeSurface: ViewModifier {
    @AppStorage("wallume.theme") private var themeName = WallumeTheme.tide.rawValue
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = palette(for: WallumeTheme(rawValue: themeName) ?? .tide, scheme: colorScheme)
        content
            .background(
                LinearGradient(colors: palette.canvas, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            )
            .tint(palette.accent)
    }

    private func palette(for theme: WallumeTheme, scheme: ColorScheme) -> (canvas: [Color], accent: Color) {
        let dark = scheme == .dark
        return switch theme {
        case .tide:
            (dark ? [Color(red: 0.035, green: 0.075, blue: 0.1), Color(red: 0.06, green: 0.13, blue: 0.16)] : [Color(red: 0.92, green: 0.98, blue: 0.98), Color(red: 0.95, green: 0.97, blue: 1.0)], Color(red: 0.0, green: 0.55, blue: 0.52))
        case .grove:
            (dark ? [Color(red: 0.045, green: 0.09, blue: 0.065), Color(red: 0.12, green: 0.14, blue: 0.075)] : [Color(red: 0.94, green: 0.98, blue: 0.91), Color(red: 0.98, green: 0.97, blue: 0.9)], Color(red: 0.22, green: 0.53, blue: 0.31))
        case .ember:
            (dark ? [Color(red: 0.13, green: 0.055, blue: 0.055), Color(red: 0.12, green: 0.08, blue: 0.04)] : [Color(red: 1.0, green: 0.94, blue: 0.91), Color(red: 1.0, green: 0.97, blue: 0.87)], Color(red: 0.82, green: 0.28, blue: 0.16))
        case .graphite:
            (dark ? [Color(red: 0.075, green: 0.09, blue: 0.12), Color(red: 0.12, green: 0.1, blue: 0.15)] : [Color(red: 0.94, green: 0.95, blue: 0.99), Color(red: 0.96, green: 0.93, blue: 0.99)], Color(red: 0.18, green: 0.39, blue: 0.66))
        }
    }
}

private struct WallumeInteractiveSurface: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.012 : 1)
            .shadow(color: .black.opacity(isHovered ? 0.08 : 0.02), radius: isHovered ? 10 : 2, y: isHovered ? 5 : 1)
            .animation(WallumeDesign.motion, value: isHovered)
            .onHover { isHovered = $0 }
    }
}
