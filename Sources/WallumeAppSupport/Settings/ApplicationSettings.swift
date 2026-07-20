import Foundation

public struct ApplicationSettings: Equatable, Sendable {
    public var launchAtLogin: Bool
    public var openGalleryAtLaunch: Bool
    public var pauseInLowPowerMode: Bool

    public init(
        launchAtLogin: Bool,
        openGalleryAtLaunch: Bool,
        pauseInLowPowerMode: Bool
    ) {
        self.launchAtLogin = launchAtLogin
        self.openGalleryAtLaunch = openGalleryAtLaunch
        self.pauseInLowPowerMode = pauseInLowPowerMode
    }
}
