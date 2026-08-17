import ExtensionFoundation
import Foundation
import WallumeWallpaperProviderPOC

/// Entry point used only to compile the lifecycle shape of a future `.appex` fixture.
///
/// This executable is never launched from the shared development account. Packaging it as an
/// extension and registering it with macOS are intentionally separate future actions.
@main
final class WallumeWallpaperProviderFixture: NSObject, AppExtension {
    override required init() {
        super.init()
    }

    var configuration: some AppExtensionConfiguration {
        WallpaperProviderExperimentConfiguration()
    }
}
