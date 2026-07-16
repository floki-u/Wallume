import AppKit
import Darwin
import Foundation
import WallumeCore

@MainActor
final class WallpaperRuntimeApplication {
    private let media: MediaItem
    private let benchmark: RuntimeBenchmarkConfiguration?
    private let coordinator: RuntimeCoordinator
    private let screens: AppKitScreenProvider
    private let windows: DesktopWindowController
    private let environmentMonitor: RuntimeEnvironmentMonitor
    private let occlusionMonitor = WindowOcclusionMonitor()
    private var environment = RuntimeEnvironment.active
    private var appObscured = false
    private var latestSnapshot: RuntimeSnapshot?
    private var interruptSource: DispatchSourceSignal?
    private var benchmarkTimer: DispatchSourceTimer?
    private var benchmarkSampler: (any RuntimeMetricSampling)?
    private var benchmarkSamples = [RuntimeMetricSample]()

    init(media: MediaItem, benchmark: RuntimeBenchmarkConfiguration? = nil) {
        self.media = media
        self.benchmark = benchmark
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
        startBenchmarkIfNeeded()
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
        var pauseReasons = environment.pauseReasons
        if appObscured { pauseReasons.insert(.appObscured) }
        if benchmark?.scenario == .paused { pauseReasons.insert(.user) }
        let snapshot = await coordinator.reconcile(
            displays: displayIDs,
            assignments: assignments,
            environment: RuntimeEnvironment(pauseReasons: pauseReasons)
        )
        latestSnapshot = snapshot
        let windowFailures = windows.reconcile(currentScreens)
        windows.apply(snapshot: snapshot, mediaByID: [media.id: media])
        for failure in snapshot.failures {
            writeError("runtime \(failure.displayID.rawValue): \(failure.message)\n")
        }
        for failure in windowFailures {
            writeError("window \(failure.displayID.rawValue): \(failure.message)\n")
        }
    }

    private func startBenchmarkIfNeeded() {
        guard let benchmark else { return }
        let sampler = ProcessRuntimeMetricSampler()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let deadline = Date().addingTimeInterval(benchmark.duration)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                self.benchmarkSamples.append(try sampler.sample())
            } catch {
                writeError("benchmark sample error: \(error)\n")
            }
            if Date() >= deadline { self.finishBenchmark(benchmark) }
        }
        benchmarkSampler = sampler
        benchmarkTimer = timer
        timer.resume()
    }

    private func finishBenchmark(_ benchmark: RuntimeBenchmarkConfiguration) {
        benchmarkTimer?.cancel()
        benchmarkTimer = nil
        benchmarkSampler = nil
        stopMonitors()

        let report = RuntimeBenchmarkReport(
            timestamp: Date(),
            scenario: benchmark.scenario,
            hardwareModel: RuntimeHostInfo.hardwareModel,
            operatingSystem: RuntimeHostInfo.operatingSystem,
            displayCount: screens.screens.count,
            mediaWidth: media.pixelWidth,
            mediaHeight: media.pixelHeight,
            mediaFramesPerSecond: media.frameRate,
            samples: benchmarkSamples,
            pauseReasons: latestSnapshot?.pauseReasons ?? [],
            sharedResourceCount: latestSnapshot?.resourceReferenceCounts.count ?? 0,
            gpuStatus: .notMeasured
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(report)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        } catch {
            writeError("benchmark report error: \(error)\n")
        }
        NSApplication.shared.terminate(nil)
    }

    private func stopMonitors() {
        screens.stop()
        environmentMonitor.stop()
        occlusionMonitor.stop()
    }

    private func installInterruptHandler() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in
            self?.benchmarkTimer?.cancel()
            self?.stopMonitors()
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
    guard let configuration = RuntimeLaunchConfiguration.parse(arguments) else {
        writeError("usage: wallume-runtime <media-uuid>\n")
        writeError("       wallume-runtime benchmark <media-uuid> --duration <5...3600> --scenario <single-1080p|single-4k|dual-shared|paused>\n")
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
        guard let media = try library.item(id: configuration.mediaID) else {
            writeError("media not found: \(configuration.mediaID.uuidString)\n")
            return 2
        }
        let application = WallpaperRuntimeApplication(media: media, benchmark: configuration.benchmark)
        application.run()
        return 0
    } catch {
        writeError("runtime error: \(error)\n")
        return 2
    }
}

exit(launch())
