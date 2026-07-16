import AppKit
import Darwin
import Foundation
import WallumeCore

@MainActor
final class WallpaperRuntimeApplication {
    private let media: MediaItem
    private let coordinator: RuntimeCoordinator
    private let screens: AppKitScreenProvider
    private let windows: DesktopWindowController
    private let environmentMonitor: RuntimeEnvironmentMonitor
    private let occlusionMonitor = WindowOcclusionMonitor()
    private var environment = RuntimeEnvironment.active
    private var appObscured = false
    private var interruptSource: DispatchSourceSignal?

    init(media: MediaItem) {
        self.media = media
        let registry = AVPlayerPresentationRegistry()
        coordinator = RuntimeCoordinator(
            catalog: SingleMediaCatalog(media: media),
            pool: PlayerPool(factory: AVFoundationPlayerFactory(registry: registry))
        )
        screens = AppKitScreenProvider()
        windows = DesktopWindowController(factory: AppKitDesktopSurfaceFactory(registry: registry))
        environmentMonitor = RuntimeEnvironmentMonitor()
    }

    func run() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        screens.start { [weak self] in self?.scheduleReconcile() }
        environmentMonitor.start { [weak self] environment in
            self?.environment = environment
            self?.scheduleReconcile()
        }
        occlusionMonitor.start(displays: screens.screens) { [weak self] obscured in
            self?.appObscured = obscured; self?.scheduleReconcile()
        }
        installInterruptHandler()
        scheduleReconcile()
        NSApplication.shared.run()
    }

    private func scheduleReconcile() {
        Task { @MainActor [weak self] in await self?.reconcile() }
    }

    private func reconcile() async {
        let currentScreens = screens.screens
        occlusionMonitor.updateDisplays(currentScreens)
        let displayIDs = Set(currentScreens.map(\.id))
        let assignments = Set(displayIDs.map { RuntimeAssignment(displayID: $0, mediaID: media.id) })
        let snapshot = await coordinator.reconcile(
            displays: displayIDs,
            assignments: assignments,
            environment: RuntimeEnvironment(
                userPaused: environment.pauseReasons.contains(.user),
                appObscured: appObscured,
                screenLocked: environment.pauseReasons.contains(.screenLocked),
                lowPowerMode: environment.pauseReasons.contains(.lowPower),
                systemSleeping: environment.pauseReasons.contains(.systemSleep)
            )
        )
        let windowFailures = windows.reconcile(currentScreens)
        windows.apply(snapshot: snapshot, mediaByID: [media.id: media])
        for failure in snapshot.failures {
            writeError("runtime \(failure.displayID.rawValue): \(failure.message)\n")
        }
        for failure in windowFailures {
            writeError("window \(failure.displayID.rawValue): \(failure.message)\n")
        }
    }

    private func installInterruptHandler() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in
            self?.screens.stop()
            self?.environmentMonitor.stop()
            self?.occlusionMonitor.stop()
            NSApplication.shared.terminate(nil)
        }
        source.resume()
        interruptSource = source
    }
}

private struct SingleMediaCatalog: MediaCatalog {
    let media: MediaItem
    func item(id: UUID) throws -> MediaItem? { id == media.id ? media : nil }
}

private func writeError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

@MainActor
private func launch() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 1, let id = UUID(uuidString: arguments[0]) else {
        writeError("usage: wallume-runtime <media-uuid>\n")
        return 64
    }

    do {
        let environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let cache = URL(
            fileURLWithPath: environment["XDG_CACHE_HOME"] ?? home.appending(path: "Library/Caches").path,
            isDirectory: true
        )
        let files = LocalFileStore()
        let library = MediaLibrary(
            paths: MediaPaths(homeDirectory: home, cacheDirectory: cache),
            files: files,
            jsonStore: AtomicJSONStore(files: files)
        )
        guard let media = try library.item(id: id) else {
            writeError("media not found: \(id.uuidString)\n")
            return 2
        }
        let application = WallpaperRuntimeApplication(media: media)
        application.run()
        return 0
    } catch {
        writeError("runtime error: \(error)\n")
        return 2
    }
}

exit(launch())
