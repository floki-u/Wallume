import AppKit
import SwiftUI
import WallumeAppSupport
import WallumeCore

@MainActor
final class ApplicationController: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let queue: ImportQueue
    private let taskStore: ImportTaskStore
    private let gallery: GalleryStore
    private let library: MediaLibrary
    private let assignmentStore: DisplayAssignmentStore
    private let displayStore: DisplayFeatureStore
    private let screens: AppKitScreenProvider
    private let runtimeService: WallpaperRuntimeService
    private let navigation = ApplicationNavigation()
    private let panels = ImportPanelController()
    private let notifier: any CompletionNotifying
    private var window: MainWindowController!
    private var status: StatusItemController!
    private var queueObservationTask: Task<Void, Never>?
    private var assignmentObservationTask: Task<Void, Never>?
    private var runtimeObservationTask: Task<Void, Never>?
    private var latestAssignments = DisplayAssignmentSnapshot.empty
    private var latestRuntime = WallpaperRuntimeSnapshot.empty

    override init() {
        let environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let cache = URL(fileURLWithPath: environment["XDG_CACHE_HOME"] ?? home.appending(path: "Library/Caches").path, isDirectory: true)
        let files = LocalFileStore()
        let jsonStore = AtomicJSONStore(files: files)
        let paths = MediaPaths(homeDirectory: home, cacheDirectory: cache)
        let library = MediaLibrary(paths: paths, files: files, jsonStore: jsonStore)
        let importer = MediaImporter(
            paths: paths, files: files, library: library,
            inspector: AVFoundationMediaInspector(),
            transcoder: AVFoundationMediaTranscoder(),
            artwork: AVFoundationArtworkGenerator()
        )
        let queue = ImportQueue(importer: importer)
        let taskStore = ImportTaskStore(queue: queue)
        let assignmentStore = DisplayAssignmentStore(
            url: paths.displayAssignments,
            files: files,
            jsonStore: jsonStore,
            library: library
        )
        let screens = AppKitScreenProvider()
        let registry = AVPlayerPresentationRegistry()
        let pool = PlayerPool(factory: AVFoundationPlayerFactory(registry: registry))
        let runtimeCoordinator = RuntimeCoordinator(catalog: library, pool: pool)
        let windows = DesktopWindowController(factory: AppKitDesktopSurfaceFactory(registry: registry))
        let runtimeService = WallpaperRuntimeService(
            screens: screens,
            environmentMonitor: RuntimeEnvironmentMonitor(),
            occlusionMonitor: WindowOcclusionMonitor(),
            runtime: runtimeCoordinator,
            windows: windows,
            catalog: library
        )
        let displayStore = DisplayFeatureStore(commands: DisplayFeatureCommands(
            assign: { mediaID, displayIDs in
                let targets = await MainActor.run {
                    screens.screens.filter { displayIDs.contains($0.id) }
                }
                guard targets.count == displayIDs.count else {
                    throw DisplayAssignmentStoreError.emptyTargets
                }
                try await assignmentStore.assign(mediaID: mediaID, to: targets)
            },
            remove: { try await assignmentStore.removeAssignment(displayID: $0) },
            clear: { try await assignmentStore.clearRememberedDisplay(displayID: $0) },
            setMode: { try await assignmentStore.setPresentationMode($0, displayID: $1) },
            setPaused: { try await assignmentStore.setUserPaused($0) },
            retry: { _ in await MainActor.run { runtimeService.retry() } }
        ))

        self.library = library
        self.queue = queue
        self.taskStore = taskStore
        self.assignmentStore = assignmentStore
        self.displayStore = displayStore
        self.screens = screens
        self.runtimeService = runtimeService
        gallery = GalleryStore(
            library: library,
            usage: PersistedMediaUsageChecker(url: paths.displayAssignments, files: files, store: jsonStore)
        )
        notifier = UserCompletionNotifier()
        super.init()

        window = MainWindowController { [gallery, taskStore, displayStore, navigation, panels, queue] in
            AnyView(ApplicationShellView(
                gallery: gallery,
                tasks: taskStore,
                displays: displayStore,
                navigation: navigation,
                onImportFiles: { let urls = panels.chooseFiles(); Task { await queue.enqueue(urls) } },
                onImportFolder: { let urls = panels.chooseFolders(); Task { await queue.enqueue(urls) } },
                onDrop: { urls in Task { await queue.enqueue(urls) } }
            ))
        }
        status = StatusItemController(
            onOpen: { [weak window, navigation] in navigation.open(.gallery); window?.show() },
            onCancelCurrent: { [taskStore] in taskStore.cancelCurrent() },
            onCancelAll: { [taskStore] in taskStore.cancelAll() },
            onOpenDisplays: { [weak window, navigation] in navigation.open(.displays); window?.show() },
            onSetUserPaused: { [assignmentStore, displayStore] paused in
                Task {
                    do { try await assignmentStore.setUserPaused(paused) }
                    catch { displayStore.reportPageError(error.localizedDescription) }
                }
            }
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        gallery.reload()
        taskStore.start()
        observeQueue()
        startDisplayRuntime()
        let state = ApplicationState(
            hasLaunchedBefore: defaults.bool(forKey: "hasLaunchedBefore"),
            openGalleryAtLaunch: defaults.bool(forKey: "openGalleryAtLaunch")
        )
        defaults.set(true, forKey: "hasLaunchedBefore")
        if state.shouldOpenWindowAtLaunch { window.show() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { [queue, runtimeService] in
            if await TerminationPolicy.decision(queue: queue) == .requestConfirmation {
                let alert = NSAlert()
                alert.messageText = "导入仍在进行"
                alert.informativeText = "退出会取消当前项和所有等待项目，已完成的导入会保留。"
                alert.addButton(withTitle: "取消导入并退出")
                alert.addButton(withTitle: "继续后台导入")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    NSApplication.shared.reply(toApplicationShouldTerminate: false)
                    return
                }
                await queue.cancelAllAndWait()
            }
            await runtimeService.stop()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        queueObservationTask?.cancel()
        assignmentObservationTask?.cancel()
        runtimeObservationTask?.cancel()
    }

    private func startDisplayRuntime() {
        Task { [weak self, assignmentStore] in
            guard let self else { return }
            do {
                latestAssignments = try await assignmentStore.load()
            } catch {
                latestAssignments = .empty
                displayStore.reportPageError("显示器配置无法读取：\(error.localizedDescription)")
            }
            runtimeService.start(assignments: latestAssignments)
            refreshDisplayState()
            observeAssignments()
            observeRuntime()
        }
    }

    private func observeAssignments() {
        assignmentObservationTask = Task { [weak self, assignmentStore] in
            let stream = await assignmentStore.events()
            for await snapshot in stream {
                guard let self else { return }
                latestAssignments = snapshot
                runtimeService.apply(assignments: snapshot)
                gallery.reload()
                refreshDisplayState()
            }
        }
    }

    private func observeRuntime() {
        runtimeObservationTask = Task { [weak self, runtimeService] in
            let stream = runtimeService.events()
            for await snapshot in stream {
                guard let self else { return }
                latestRuntime = snapshot
                status.updatePlayback(
                    activeDisplayCount: snapshot.activeDisplayCount,
                    pauseReasons: snapshot.runtime.pauseReasons,
                    userPaused: latestAssignments.userPaused
                )
                refreshDisplayState()
            }
        }
    }

    private func refreshDisplayState() {
        let catalog = DisplayCatalog.merge(
            connected: screens.screens,
            remembered: latestAssignments.records
        )
        let media = (try? library.list()) ?? []
        displayStore.update(
            catalog: catalog,
            assignments: latestAssignments,
            media: media,
            runtime: latestRuntime.runtime
        )
    }

    private func observeQueue() {
        queueObservationTask = Task { [weak self, queue] in
            let stream = await queue.events()
            var wasActive = false
            var processed = 0
            for await snapshot in stream {
                guard let self else { return }
                status.update(snapshot)
                if snapshot.summary.processed > processed {
                    gallery.reload()
                    refreshDisplayState()
                }
                if wasActive && !snapshot.isActive {
                    gallery.reload()
                    refreshDisplayState()
                    if ApplicationState.shouldNotifyOnCompletion(
                        windowVisible: window.isVisible,
                        applicationActive: NSApplication.shared.isActive
                    ) {
                        await notifier.notify(title: "Wallume 导入完成", body: Self.summaryText(snapshot.summary))
                    }
                }
                wasActive = snapshot.isActive
                processed = snapshot.summary.processed
            }
        }
    }

    private static func summaryText(_ summary: ImportQueueSummary) -> String {
        "成功 \(summary.imported)，重复 \(summary.duplicate)，失败 \(summary.failed)，取消 \(summary.cancelled)"
    }
}
