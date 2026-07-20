import SwiftUI
import WallumeCore

public enum ApplicationShellRoute: Equatable, Sendable {
    case gallery
    case displays
    case lockScreen
    case performance
    case unavailable

    public static func resolve(
        selection: WallumeFeatureID,
        hasDisplayStore: Bool,
        hasLockScreenStore: Bool,
        hasPerformanceStore: Bool = false
    ) -> Self {
        switch selection {
        case .gallery:
            .gallery
        case .displays where hasDisplayStore:
            .displays
        case .lockScreen where hasLockScreenStore:
            .lockScreen
        case .performance where hasPerformanceStore:
            .performance
        case .displays, .lockScreen, .performance, .settings:
            .unavailable
        }
    }
}

@MainActor
public final class LockScreenApplicationComposition {
    public let service: LockScreenSyncService
    public let store: LockScreenFeatureStore

    public init(
        configurationURL: URL,
        files: any FileStore,
        makeSystemClient: () throws -> any LockScreenSystemClient
    ) {
        let client: any LockScreenSystemClient
        do {
            client = try makeSystemClient()
        } catch {
            client = UnavailableLockScreenSystemClient(message: error.localizedDescription)
        }
        service = LockScreenSyncService(
            configurationStore: LockScreenConfigurationStore(
                url: configurationURL,
                files: files,
                jsonStore: AtomicJSONStore(files: files)
            ),
            systemClient: client,
            files: files
        )
        store = LockScreenFeatureStore(service: service)
    }
}

/// Owns the sole performance service/store pair used by the application shell.
@MainActor
public final class PerformanceApplicationComposition {
    public let service: PerformanceDiagnosticsService
    public let store: PerformanceFeatureStore

    public init(service: PerformanceDiagnosticsService = PerformanceDiagnosticsService()) {
        self.service = service
        store = PerformanceFeatureStore(service: service)
    }
}

/// Keeps shutdown ownership explicit and testable. Callers provide their existing shutdown
/// operations; this helper only establishes the required ordering.
public struct ApplicationTerminationCommands: Sendable {
    private let stopLockScreen: @Sendable () async -> Void
    private let stopDiagnostics: @Sendable () async -> Void
    private let stopRuntime: @Sendable () async -> Void

    public init(
        stopLockScreen: @escaping @Sendable () async -> Void,
        stopDiagnostics: @escaping @Sendable () async -> Void,
        stopRuntime: @escaping @Sendable () async -> Void
    ) {
        self.stopLockScreen = stopLockScreen
        self.stopDiagnostics = stopDiagnostics
        self.stopRuntime = stopRuntime
    }

    public func stopServices() async {
        await stopLockScreen()
        await stopDiagnostics()
        await stopRuntime()
    }
}

private struct UnavailableLockScreenSystemClient: LockScreenSystemClient {
    let message: String

    func probe() throws -> LockScreenProbeReport { try unavailable() }
    func install(media: MediaItem, aerialID: String) throws -> LockScreenTransactionManifest {
        try unavailable()
    }
    func inspectRecovery() throws -> [RecoveryCandidate] { try unavailable() }
    func restore(transactionID: UUID) throws -> RecoveryReport { try unavailable() }

    private func unavailable<Value>() throws -> Value {
        throw UnavailableLockScreenSystemClientError(message: message)
    }
}

private struct UnavailableLockScreenSystemClientError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

public struct PlaybackToolbarState: Equatable, Sendable {
    public let userPaused: Bool
    public let pauseReasons: Set<RuntimePauseReason>

    public init(userPaused: Bool, pauseReasons: Set<RuntimePauseReason>) {
        self.userPaused = userPaused
        self.pauseReasons = pauseReasons
    }

    public var statusText: String? {
        !pauseReasons.isEmpty && !userPaused ? "已因系统状态暂停" : nil
    }
    public var actionTitle: String { userPaused ? "继续播放" : "暂停播放" }
}

public struct ApplicationShellView: View {
    @Bindable private var navigation: ApplicationNavigation
    private let gallery: GalleryStore
    private let tasks: ImportTaskStore
    private let displays: DisplayFeatureStore?
    private let lockScreen: LockScreenFeatureStore?
    private let performance: PerformanceFeatureStore?
    private let openSystemWallpaperSettings: () -> Void
    private let onImportFiles: () -> Void
    private let onImportFolder: () -> Void
    private let onDrop: ([URL]) -> Void

    public init(gallery: GalleryStore, tasks: ImportTaskStore, displays: DisplayFeatureStore? = nil, lockScreen: LockScreenFeatureStore? = nil, performance: PerformanceFeatureStore? = nil, navigation: ApplicationNavigation = ApplicationNavigation(), openSystemWallpaperSettings: @escaping () -> Void = {}, onImportFiles: @escaping () -> Void, onImportFolder: @escaping () -> Void, onDrop: @escaping ([URL]) -> Void) {
        self.gallery = gallery; self.tasks = tasks; self.displays = displays; self.lockScreen = lockScreen; self.performance = performance; self.navigation = navigation; self.openSystemWallpaperSettings = openSystemWallpaperSettings; self.onImportFiles = onImportFiles; self.onImportFolder = onImportFolder; self.onDrop = onDrop
    }

    public var body: some View {
        NavigationSplitView {
            List(FeatureRegistry.features, selection: $navigation.selection) { feature in
                Label(feature.title, systemImage: feature.systemImage).tag(feature.id)
            }.navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch ApplicationShellRoute.resolve(
                selection: navigation.selection,
                hasDisplayStore: displays != nil,
                hasLockScreenStore: lockScreen != nil,
                hasPerformanceStore: performance != nil
            ) {
            case .gallery:
                GalleryView(
                    gallery: gallery,
                    tasks: tasks,
                    displays: displays,
                    preferredAssignmentDisplayID: navigation.preferredAssignmentDisplayID,
                    onAssignmentFlowFinished: { navigation.clearWallpaperTarget() },
                    onImportFiles: onImportFiles,
                    onImportFolder: onImportFolder,
                    onDrop: onDrop
                )
            case .displays:
                if let displays {
                    DisplaysView(store: displays) { navigation.openGalleryForWallpaper(displayID: $0) }
                }
            case .lockScreen:
                if let lockScreen {
                    LockScreenView(
                        store: lockScreen,
                        openSystemWallpaperSettings: openSystemWallpaperSettings
                    )
                }
            case .performance:
                if let performance {
                    PerformanceView(store: performance)
                }
            case .unavailable:
                ContentUnavailableView("将在后续批次开放", systemImage: FeatureRegistry.features.first { $0.id == navigation.selection }?.systemImage ?? "hammer")
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            if let displays {
                let playback = PlaybackToolbarState(
                    userPaused: displays.userPaused,
                    pauseReasons: displays.effectivePauseReasons
                )
                ToolbarItemGroup {
                    if let status = playback.statusText {
                        Label(status, systemImage: "pause.circle.fill")
                    }
                    Button(playback.actionTitle) {
                        Task { await displays.setUserPaused(!displays.userPaused) }
                    }
                }
            }
        }
    }
}
