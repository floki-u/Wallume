import Foundation
import WallumeAppSupport

@main
struct WallumeProviderCleanup {
    static func main() async {
        let command = CommandLine.arguments.dropFirst().first
        let paths = NativeWallpaperProviderPaths(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        let lifecycle = NativeWallpaperProviderLifecycle(paths: paths)

        do {
            switch command {
            case "status":
                if let deployment = try await lifecycle.deployment() {
                    print("provider: \(deployment.providerIdentifier)")
                    print("activeInSystem: \(deployment.isActiveInSystem)")
                    print("mediaID: \(deployment.mediaID.uuidString)")
                } else {
                    print("provider: none")
                }
            case "confirm-system-reset":
                try await lifecycle.confirmSystemReset()
                print("System reset recorded. Run wallume-provider-cleanup cleanup to remove Wallume provider files.")
            case "cleanup":
                try await lifecycle.cleanupAfterReset()
                print("Wallume provider cache removed.")
            default:
                writeUsage()
                Foundation.exit(64)
            }
        } catch NativeWallpaperProviderLifecycleError.resetRequired {
            fputs("Wallume provider cache is still selected. Choose another wallpaper in System Settings first, then run confirm-system-reset.\n", stderr)
            Foundation.exit(2)
        } catch {
            fputs("wallume-provider-cleanup: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func writeUsage() {
        print("usage: wallume-provider-cleanup status | confirm-system-reset | cleanup")
    }
}
