import SwiftUI

/// Shared presentation primitives. These keep the feature pages visually coherent while
/// leaving all feature state and actions in their existing stores.
public enum WallumeDesign {
    public static let accent = Color(red: 0.34, green: 0.38, blue: 0.92)
    public static let cardCornerRadius: CGFloat = 18
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
                Text(title).font(.largeTitle.bold())
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
        background {
            LinearGradient(
                colors: [
                    WallumeDesign.accent.opacity(0.10),
                    Color.clear,
                    Color.primary.opacity(0.025),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .tint(WallumeDesign.accent)
    }

    func wallumeCard() -> some View {
        padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08))
            }
    }
}
