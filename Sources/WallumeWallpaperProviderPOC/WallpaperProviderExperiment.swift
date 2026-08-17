import ExtensionFoundation
import Foundation
import WallumeWallpaperPOC

/// Compile-only shape for the private wallpaper-provider investigation.
///
/// This is deliberately not an extension bundle: there is no `@main`, Info.plist, or
/// ExtensionKit registration. Should this type ever be embedded in an isolated POC bundle,
/// its configuration still rejects every connection until an explicit future activation gate
/// is designed and reviewed.
public final class WallpaperProviderExperiment: NSObject, AppExtension {
    public override init() {
        super.init()
    }

    public var configuration: some AppExtensionConfiguration {
        WallpaperProviderExperimentConfiguration()
    }
}

public struct WallpaperProviderExperimentConfiguration: AppExtensionConfiguration {
    public init() {}

    public func accept(connection _: NSXPCConnection) -> Bool {
        false
    }
}

public enum WallpaperProviderExperimentSafety {
    /// This target must remain non-activating in the shared development account.
    public static let acceptsConnections = false

    public static let prohibitedCapabilities = [
        "AppExtension entry point",
        "ExtensionKit registration",
        "WallpaperAgent XPC connection",
        "remote CAContext creation",
        "wallpaper-store access",
    ]

    public static let declaredHostToProviderSelectors = WallpaperExtensionProtocolSurface.hostToProviderSelectors
    public static let declaredProviderToHostSelectors = WallpaperExtensionProtocolSurface.providerToHostSelectors
}
