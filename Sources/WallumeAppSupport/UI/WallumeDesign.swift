import AppKit
import SwiftUI

/// Shared presentation primitives. These keep the feature pages visually coherent while
/// leaving all feature state and actions in their existing stores.
public enum WallumeDesign {
    public static let accent = Color(red: 0.02, green: 0.6, blue: 0.56)
    public static let warmAccent = Color(red: 0.94, green: 0.34, blue: 0.25)
    public static let ink = Color(red: 0.08, green: 0.1, blue: 0.12)
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
                Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
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
        background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .tint(WallumeDesign.accent)
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

private struct WallumeInteractiveSurface: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.012 : 1)
            .shadow(color: .black.opacity(isHovered ? 0.12 : 0.04), radius: isHovered ? 16 : 5, y: isHovered ? 8 : 2)
            .animation(WallumeDesign.motion, value: isHovered)
            .onHover { isHovered = $0 }
    }
}
