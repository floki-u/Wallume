import SwiftUI
import WallumeCore

package final class LockScreenDiagnosticsSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = LockScreenDiagnosticsSummary.unavailable
    private var errorPresent = false

    package init() {}

    package var value: LockScreenDiagnosticsSummary { lock.withLock { storage } }

    package var recentTransactions: DiagnosticsRecentTransactionSummary {
        lock.withLock {
            guard let succeeded = storage.lastTransactionSucceeded else { return .unavailable }
            return .init(
                status: .available,
                completedCount: succeeded ? 1 : 0,
                failedCount: succeeded ? 0 : 1
            )
        }
    }

    package var currentError: DiagnosticsCurrentErrorSummary {
        lock.withLock { errorPresent ? .present : .none }
    }

    package func update(_ state: LockScreenSyncState) {
        lock.withLock {
            storage = LockScreenDiagnosticsSummary(state: state)
            errorPresent = state.lastError != nil
        }
    }
}

public enum ApplicationShellRoute: Equatable, Sendable {
    case gallery
    case displays
    case lockScreen
    case performance
    case settings
    case unavailable

    public static func resolve(
        selection: WallumeFeatureID,
        hasDisplayStore: Bool,
        hasLockScreenStore: Bool,
        hasPerformanceStore: Bool = false,
        hasSettingsStore: Bool = false
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
        case .settings where hasSettingsStore:
            .settings
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

/// Owns the application-lifetime export task so termination can cancel and await it.
/// The Settings view only requests exports; it never owns their termination lifecycle.
public actor SettingsDiagnosticsExportTerminationOwner {
    private struct InFlightExport {
        let id: UUID
        let task: Task<Void, Error>
    }

    private var inFlightExport: InFlightExport?
    private var isTerminating = false
    private let commitAdmission: DiagnosticsExportCommitAdmission

    public init(commitAdmission: DiagnosticsExportCommitAdmission = .init()) { self.commitAdmission = commitAdmission }

    public func perform(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        guard !isTerminating, inFlightExport == nil else { throw CancellationError() }

        let export = InFlightExport(
            id: UUID(),
            task: Task { try await operation() }
        )
        inFlightExport = export
        defer { clearExport(id: export.id) }
        try await export.task.value
    }

    public func cancelAndWait() async {
        isTerminating = true
        await commitAdmission.terminateAndWait()
        guard let export = inFlightExport else { return }
        export.task.cancel()
        _ = try? await export.task.value
        clearExport(id: export.id)
    }

    private func clearExport(id: UUID) {
        guard inFlightExport?.id == id else { return }
        inFlightExport = nil
    }
}

/// Keeps shutdown ownership explicit and testable. Callers provide their existing shutdown
/// operations; this helper only establishes the required ordering.
@MainActor
public struct ApplicationTerminationCommands {
    private let cancelSettingsExport: () async -> Void
    private let stopLockScreen: () async -> Void
    private let stopDiagnostics: () async -> Void
    private let stopRuntime: () async -> Void

    public init(
        cancelSettingsExport: @escaping () async -> Void,
        stopLockScreen: @escaping () async -> Void,
        stopDiagnostics: @escaping () async -> Void,
        stopRuntime: @escaping () async -> Void
    ) {
        self.cancelSettingsExport = cancelSettingsExport
        self.stopLockScreen = stopLockScreen
        self.stopDiagnostics = stopDiagnostics
        self.stopRuntime = stopRuntime
    }

    public func stopServices() async {
        await cancelSettingsExport()
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
    private let nativeWallpaperProvider: NativeWallpaperProviderStore?
    private let performance: PerformanceFeatureStore?
    private let settings: SettingsStore?
    private let settingsBuildInfo: SettingsBuildInfo
    private let settingsDataDirectory: URL
    private let settingsDiagnosticsDirectory: URL
    private let openInFinder: (URL) -> Void
    private let chooseDiagnosticsExportDestination: () -> URL?
    private let exportDiagnostics: (URL) async throws -> Void
    private let openSystemWallpaperSettings: () -> Void
    private let onImportFiles: () -> Void
    private let onImportFolder: () -> Void
    private let onDrop: ([URL]) -> Void

    public init(
        gallery: GalleryStore,
        tasks: ImportTaskStore,
        displays: DisplayFeatureStore? = nil,
        lockScreen: LockScreenFeatureStore? = nil,
        nativeWallpaperProvider: NativeWallpaperProviderStore? = nil,
        performance: PerformanceFeatureStore? = nil,
        settings: SettingsStore? = nil,
        settingsBuildInfo: SettingsBuildInfo = .unavailable,
        settingsDataDirectory: URL = URL(fileURLWithPath: "/"),
        settingsDiagnosticsDirectory: URL = URL(fileURLWithPath: "/"),
        openInFinder: @escaping (URL) -> Void = { _ in },
        chooseDiagnosticsExportDestination: @escaping () -> URL? = { nil },
        exportDiagnostics: @escaping (URL) async throws -> Void = { _ in },
        navigation: ApplicationNavigation = ApplicationNavigation(),
        openSystemWallpaperSettings: @escaping () -> Void = {},
        onImportFiles: @escaping () -> Void,
        onImportFolder: @escaping () -> Void,
        onDrop: @escaping ([URL]) -> Void
    ) {
        self.gallery = gallery
        self.tasks = tasks
        self.displays = displays
        self.lockScreen = lockScreen
        self.nativeWallpaperProvider = nativeWallpaperProvider
        self.performance = performance
        self.settings = settings
        self.settingsBuildInfo = settingsBuildInfo
        self.settingsDataDirectory = settingsDataDirectory
        self.settingsDiagnosticsDirectory = settingsDiagnosticsDirectory
        self.openInFinder = openInFinder
        self.chooseDiagnosticsExportDestination = chooseDiagnosticsExportDestination
        self.exportDiagnostics = exportDiagnostics
        self.navigation = navigation
        self.openSystemWallpaperSettings = openSystemWallpaperSettings
        self.onImportFiles = onImportFiles
        self.onImportFolder = onImportFolder
        self.onDrop = onDrop
    }

    public var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    WallumeMark(size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Wallume").font(.headline.weight(.semibold))
                        Text("动态壁纸").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                List(selection: $navigation.selection) {
                    Section("工作区") {
                        ForEach(FeatureRegistry.availableFeatures(hasSettingsStore: settings != nil).filter { $0.id != .settings }) { feature in
                            Label(feature.title, systemImage: feature.systemImage).tag(feature.id)
                        }
                    }
                    if FeatureRegistry.availableFeatures(hasSettingsStore: settings != nil).contains(where: { $0.id == .settings }) {
                        Section {
                            Label("设置", systemImage: "gearshape").tag(WallumeFeatureID.settings)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .padding(.top, 16)
            .navigationSplitViewColumnWidth(min: 180, ideal: 205)
        } detail: {
            switch ApplicationShellRoute.resolve(
                selection: navigation.selection,
                hasDisplayStore: displays != nil,
                hasLockScreenStore: lockScreen != nil,
                hasPerformanceStore: performance != nil,
                hasSettingsStore: settings != nil
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
                        nativeProvider: nativeWallpaperProvider,
                        openSystemWallpaperSettings: openSystemWallpaperSettings,
                        revealStaticFallback: openInFinder
                    )
                }
            case .performance:
                if let performance {
                    PerformanceView(store: performance)
                }
            case .settings:
                if let settings {
                    SettingsView(
                        store: settings,
                        buildInfo: settingsBuildInfo,
                        dataDirectory: settingsDataDirectory,
                        diagnosticsDirectory: settingsDiagnosticsDirectory,
                        openInFinder: openInFinder,
                        chooseExportDestination: chooseDiagnosticsExportDestination,
                        exportDiagnostics: exportDiagnostics
                    )
                }
            case .unavailable:
                ContentUnavailableView("将在后续批次开放", systemImage: FeatureRegistry.features.first { $0.id == navigation.selection }?.systemImage ?? "hammer")
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .navigationSplitViewStyle(.balanced)
        .wallumePageBackground()
        .animation(WallumeDesign.motion, value: navigation.selection)
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
                    Button(playback.actionTitle, systemImage: displays.userPaused ? "play.fill" : "pause.fill") {
                        Task { await displays.setUserPaused(!displays.userPaused) }
                    }
                    .help(playback.actionTitle)
                }
            }
        }
    }
}
