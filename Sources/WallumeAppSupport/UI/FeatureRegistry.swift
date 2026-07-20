import Foundation

public enum WallumeFeatureID: String, CaseIterable, Hashable, Sendable {
    case gallery, displays, lockScreen, performance, settings
}

public struct WallumeFeature: Identifiable, Equatable, Sendable {
    public let id: WallumeFeatureID
    public let title: String
    public let systemImage: String
    public let isEnabled: Bool
}

public enum FeatureRegistry {
    public static let features: [WallumeFeature] = [
        .init(id: .gallery, title: "图库", systemImage: "square.grid.2x2", isEnabled: true),
        .init(id: .displays, title: "显示器", systemImage: "display.2", isEnabled: true),
        .init(id: .lockScreen, title: "锁屏", systemImage: "lock.display", isEnabled: true),
        .init(id: .performance, title: "性能", systemImage: "gauge.with.dots.needle.67percent", isEnabled: true),
        .init(id: .settings, title: "设置", systemImage: "gearshape", isEnabled: false),
    ]
}
