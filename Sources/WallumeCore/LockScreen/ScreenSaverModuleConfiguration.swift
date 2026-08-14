import Foundation

/// The single current-host Screen Saver preference that routes the lock screen through Apple's
/// Wallpaper Aerials extension.  It is deliberately kept separate from the wallpaper index:
/// copying or replacing the whole `com.apple.screensaver` domain would clobber unrelated user
/// choices.
public struct ScreenSaverModuleSnapshot: Codable, Equatable, Sendable {
    public let value: Data?

    public init(value: Data?) {
        self.value = value
    }
}

public protocol ScreenSaverModuleConfiguring: Sendable {
    func snapshot() throws -> ScreenSaverModuleSnapshot
    func activateWallpaperAerials() throws
    func isWallpaperAerialsActive() throws -> Bool
    func restore(_ snapshot: ScreenSaverModuleSnapshot) throws
}

public enum ScreenSaverModuleConfigurationError: Error, Equatable, Sendable {
    case unreadablePreference
    case unwritablePreference
}

/// Current-user/current-host adapter.  The documented preference APIs are used only to configure
/// the existing Apple extension; no system file or third-party screen saver is installed.
public struct CurrentHostScreenSaverModuleConfiguration: ScreenSaverModuleConfiguring {
    public init() {}

    public func snapshot() throws -> ScreenSaverModuleSnapshot {
        guard let value = CFPreferencesCopyValue(
            moduleKey,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) else {
            return ScreenSaverModuleSnapshot(value: nil)
        }
        guard CFPropertyListIsValid(value, .binaryFormat_v1_0),
              let data = try? PropertyListSerialization.data(
                  fromPropertyList: value,
                  format: .binary,
                  options: 0
              ) else {
            throw ScreenSaverModuleConfigurationError.unreadablePreference
        }
        return ScreenSaverModuleSnapshot(value: data)
    }

    public func activateWallpaperAerials() throws {
        let value: [String: Any] = [
            "moduleName": "WallpaperAerialsExtension",
            "path": "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex",
            "type": 0,
        ]
        try set(value)
    }

    public func isWallpaperAerialsActive() throws -> Bool {
        guard let data = try snapshot().value,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        return value["moduleName"] as? String == "WallpaperAerialsExtension"
            && value["path"] as? String == "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex"
    }

    public func restore(_ snapshot: ScreenSaverModuleSnapshot) throws {
        if let data = snapshot.value {
            guard let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
                throw ScreenSaverModuleConfigurationError.unreadablePreference
            }
            try set(value)
        } else {
            CFPreferencesSetValue(
                moduleKey,
                nil,
                applicationID,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
            guard CFPreferencesSynchronize(
                applicationID,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            ) else { throw ScreenSaverModuleConfigurationError.unwritablePreference }
        }
    }

    private func set(_ value: Any) throws {
        guard CFPropertyListIsValid(value as CFPropertyList, .binaryFormat_v1_0) else {
            throw ScreenSaverModuleConfigurationError.unwritablePreference
        }
        CFPreferencesSetValue(
            moduleKey,
            value as CFPropertyList,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        guard CFPreferencesSynchronize(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) else { throw ScreenSaverModuleConfigurationError.unwritablePreference }
    }

    private var applicationID: CFString { "com.apple.screensaver" as CFString }
    private var moduleKey: CFString { "moduleDict" as CFString }
}

public struct NoopScreenSaverModuleConfiguration: ScreenSaverModuleConfiguring {
    public init() {}
    public func snapshot() throws -> ScreenSaverModuleSnapshot { .init(value: nil) }
    public func activateWallpaperAerials() throws {}
    public func isWallpaperAerialsActive() throws -> Bool { true }
    public func restore(_: ScreenSaverModuleSnapshot) throws {}
}
