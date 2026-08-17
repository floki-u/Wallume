import Darwin
import Foundation

/// Read-only compatibility probe for the private wallpaper-provider experiment.
///
/// This target never declares an App Extension, connects to WallpaperAgent, or touches
/// wallpaper state. It only verifies that the runtime ingredients required by a future,
/// separately-reviewed POC exist on the host OS.
public struct WallpaperExtensionRuntimeProbe: Sendable {
    public static let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"

    public static let requiredClassNames = [
        "WallpaperRemoteContextXPC",
        "WallpaperSnapshotXPC",
        "WallpaperCreationRequestXPC",
        "WallpaperSettingsViewModelsXPC",
        "WallpaperIDXPC",
    ]

    private let libraryLoader: any DynamicLibraryLoading
    private let classIsPresent: @Sendable (String) -> Bool

    public init(
        libraryLoader: any DynamicLibraryLoading = SystemDynamicLibraryLoader(),
        classIsPresent: @escaping @Sendable (String) -> Bool = { NSClassFromString($0) != nil }
    ) {
        self.libraryLoader = libraryLoader
        self.classIsPresent = classIsPresent
    }

    public func inspect() -> WallpaperExtensionRuntimeReport {
        guard libraryLoader.open(path: Self.frameworkPath) else {
            return WallpaperExtensionRuntimeReport(
                frameworkLoaded: false,
                availableClasses: [],
                missingClasses: Self.requiredClassNames
            )
        }

        let available = Self.requiredClassNames.filter(classIsPresent)
        let missing = Self.requiredClassNames.filter { !classIsPresent($0) }
        return WallpaperExtensionRuntimeReport(
            frameworkLoaded: true,
            availableClasses: available,
            missingClasses: missing
        )
    }
}

public struct WallpaperExtensionRuntimeReport: Equatable, Sendable {
    public let frameworkLoaded: Bool
    public let availableClasses: [String]
    public let missingClasses: [String]

    public init(frameworkLoaded: Bool, availableClasses: [String], missingClasses: [String]) {
        self.frameworkLoaded = frameworkLoaded
        self.availableClasses = availableClasses
        self.missingClasses = missingClasses
    }

    public var isCompatible: Bool {
        frameworkLoaded && missingClasses.isEmpty
    }
}

public protocol DynamicLibraryLoading: Sendable {
    func open(path: String) -> Bool
}

public struct SystemDynamicLibraryLoader: DynamicLibraryLoading {
    public init() {}

    public func open(path: String) -> Bool {
        dlopen(path, RTLD_LAZY | RTLD_LOCAL) != nil
    }
}
