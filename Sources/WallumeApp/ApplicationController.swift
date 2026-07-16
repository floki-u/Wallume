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
    private let panels = ImportPanelController()
    private let notifier: any CompletionNotifying
    private var window: MainWindowController!
    private var status: StatusItemController!
    private var observationTask: Task<Void, Never>?

    override init() {
        let environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let cache = URL(fileURLWithPath: environment["XDG_CACHE_HOME"] ?? home.appending(path: "Library/Caches").path, isDirectory: true)
        let files = LocalFileStore()
        let paths = MediaPaths(homeDirectory: home, cacheDirectory: cache)
        let library = MediaLibrary(paths: paths, files: files, jsonStore: AtomicJSONStore(files: files))
        let importer = MediaImporter(paths: paths, files: files, library: library, inspector: AVFoundationMediaInspector(), transcoder: AVFoundationMediaTranscoder(), artwork: AVFoundationArtworkGenerator())
        queue = ImportQueue(importer: importer)
        taskStore = ImportTaskStore(queue: queue)
        gallery = GalleryStore(library: library, usage: PersistedMediaUsageChecker(url: paths.displayAssignments, files: files, store: AtomicJSONStore(files: files)))
        notifier = UserCompletionNotifier()
        super.init()
        window = MainWindowController { [gallery, taskStore, panels, queue] in
            AnyView(ApplicationShellView(
                gallery: gallery,
                tasks: taskStore,
                onImportFiles: { let urls = panels.chooseFiles(); Task { await queue.enqueue(urls) } },
                onImportFolder: { let urls = panels.chooseFolders(); Task { await queue.enqueue(urls) } },
                onDrop: { urls in Task { await queue.enqueue(urls) } }
            ))
        }
        status = StatusItemController(
            onOpen: { [weak window] in window?.show() },
            onCancelCurrent: { [taskStore] in taskStore.cancelCurrent() },
            onCancelAll: { [taskStore] in taskStore.cancelAll() }
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        gallery.reload()
        taskStore.start()
        observeQueue()
        let state = ApplicationState(
            hasLaunchedBefore: defaults.bool(forKey: "hasLaunchedBefore"),
            openGalleryAtLaunch: defaults.bool(forKey: "openGalleryAtLaunch")
        )
        defaults.set(true, forKey: "hasLaunchedBefore")
        if state.shouldOpenWindowAtLaunch { window.show() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { [queue] in
            guard await TerminationPolicy.decision(queue: queue) == .requestConfirmation else {
                NSApplication.shared.reply(toApplicationShouldTerminate: true); return
            }
            let alert = NSAlert()
            alert.messageText = "导入仍在进行"
            alert.informativeText = "退出会取消当前项和所有等待项目，已完成的导入会保留。"
            alert.addButton(withTitle: "取消导入并退出")
            alert.addButton(withTitle: "继续后台导入")
            if alert.runModal() == .alertFirstButtonReturn {
                await queue.cancelAllAndWait()
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            } else {
                NSApplication.shared.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    private func observeQueue() {
        observationTask = Task { [weak self, queue] in
            let stream = await queue.events()
            var wasActive = false
            var processed = 0
            for await snapshot in stream {
                guard let self else { return }
                self.status.update(snapshot)
                if snapshot.summary.processed > processed { self.gallery.reload() }
                if wasActive && !snapshot.isActive {
                    self.gallery.reload()
                    if ApplicationState.shouldNotifyOnCompletion(windowVisible: self.window.isVisible, applicationActive: NSApplication.shared.isActive) {
                        await self.notifier.notify(title: "Wallume 导入完成", body: Self.summaryText(snapshot.summary))
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
