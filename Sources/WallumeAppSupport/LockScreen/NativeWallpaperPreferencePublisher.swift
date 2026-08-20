import Foundation
import WallumeCore

/// Publishes playback preferences to the native wallpaper extension.
///
/// The extension is hosted independently by WallpaperAgent, so it cannot observe the main
/// app's display-assignment store directly. Keep this wire format aligned with `WallpaperPrefs`
/// in the extension and notify it after each atomic write.
public struct NativeWallpaperPreferencePublisher: Sendable {
    private let preferencesURL: URL
    private let files: any FileStore

    public init(
        homeDirectory: URL,
        providerIdentifier: String = "com.wallume.app.wallpaper",
        files: any FileStore
    ) {
        preferencesURL = homeDirectory.appending(
            path: "Library/Containers/\(providerIdentifier)/Data/Documents/wallume-provider-prefs.json"
        )
        self.files = files
    }

    public func publish(userPaused: Bool) throws {
        try files.createDirectory(preferencesURL.deletingLastPathComponent())
        let preferences = Preferences(userPaused: userPaused)
        try files.writeAtomically(JSONEncoder().encode(preferences), to: preferencesURL)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.wallume.app.wallpaper.prefsChanged" as CFString),
            nil,
            nil,
            true
        )
    }

    private struct Preferences: Codable, Sendable {
        let userPaused: Bool
        let alwaysPauseDesktop: Bool
        let pauseWhenOccluded: Bool
        let desktopOccluded: Bool
        let pausedDisplays: Set<UInt32>?

        init(userPaused: Bool) {
            self.userPaused = userPaused
            alwaysPauseDesktop = false
            pauseWhenOccluded = false
            desktopOccluded = false
            pausedDisplays = nil
        }
    }
}
