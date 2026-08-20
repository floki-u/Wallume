import Foundation
import Observation

@MainActor @Observable
public final class SettingsStore {
    public private(set) var settings: ApplicationSettings
    public private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let loginItem: any LoginItemControlling
    private let onSettingsChanged: @MainActor (ApplicationSettings) -> Void
    private let onPauseInLowPowerModeChanged: @MainActor (Bool) -> Void

    public init(
        defaults: UserDefaults = .standard,
        loginItem: any LoginItemControlling = MainAppLoginItemController(),
        onSettingsChanged: @escaping @MainActor (ApplicationSettings) -> Void = { _ in },
        onPauseInLowPowerModeChanged: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.loginItem = loginItem
        self.onSettingsChanged = onSettingsChanged
        self.onPauseInLowPowerModeChanged = onPauseInLowPowerModeChanged

        let launchAtLogin: Bool
        do {
            launchAtLogin = try loginItem.isEnabled()
            errorMessage = nil
        } catch {
            launchAtLogin = false
            errorMessage = Self.loginItemErrorMessage
        }
        settings = ApplicationSettings(
            launchAtLogin: launchAtLogin,
            openGalleryAtLaunch: defaults.bool(forKey: Keys.openGalleryAtLaunch),
            pauseInLowPowerMode: defaults.object(forKey: Keys.pauseInLowPowerMode) as? Bool ?? false
        )
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        let previous = settings.launchAtLogin
        guard enabled != previous else { return }

        do {
            if enabled {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
            settings.launchAtLogin = try loginItem.isEnabled()
            defaults.set(settings.launchAtLogin, forKey: Keys.launchAtLogin)
            errorMessage = nil
            onSettingsChanged(settings)
        } catch {
            settings.launchAtLogin = previous
            errorMessage = Self.loginItemErrorMessage
        }
    }

    public func setOpenGalleryAtLaunch(_ enabled: Bool) {
        settings.openGalleryAtLaunch = enabled
        defaults.set(enabled, forKey: Keys.openGalleryAtLaunch)
        errorMessage = nil
        onSettingsChanged(settings)
    }

    public func setPauseInLowPowerMode(_ enabled: Bool) {
        settings.pauseInLowPowerMode = enabled
        defaults.set(enabled, forKey: Keys.pauseInLowPowerMode)
        errorMessage = nil
        onSettingsChanged(settings)
        onPauseInLowPowerModeChanged(enabled)
    }

    public func dismissError() {
        errorMessage = nil
    }

    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let openGalleryAtLaunch = "openGalleryAtLaunch"
        static let pauseInLowPowerMode = "pauseInLowPowerMode"
    }

    private static let loginItemErrorMessage = "无法更新登录启动设置，请稍后重试。"
}
