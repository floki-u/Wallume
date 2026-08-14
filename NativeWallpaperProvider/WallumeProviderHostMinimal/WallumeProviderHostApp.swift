import SwiftUI

/// A minimal host for the embedded Wallume wallpaper extension.
///
/// Wallume owns the user experience. This target exists only because macOS loads wallpaper
/// extensions from an application bundle.
@main
struct WallumeProviderHostApp: App {
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
