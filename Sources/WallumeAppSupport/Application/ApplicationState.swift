public struct ApplicationState: Equatable, Sendable {
    public let hasLaunchedBefore: Bool
    public let openGalleryAtLaunch: Bool

    public init(hasLaunchedBefore: Bool, openGalleryAtLaunch: Bool) {
        self.hasLaunchedBefore = hasLaunchedBefore; self.openGalleryAtLaunch = openGalleryAtLaunch
    }

    public var shouldOpenWindowAtLaunch: Bool { !hasLaunchedBefore || openGalleryAtLaunch }

    public static func shouldNotifyOnCompletion(windowVisible: Bool, applicationActive: Bool) -> Bool {
        !windowVisible || !applicationActive
    }
}
