import AppKit
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
    @AppStorage("wallume.theme") private var themeName = WallumeTheme.nocturne.rawValue
    @AppStorage("wallume.language") private var languageName = WallumeAppLanguage.chinese.rawValue
    @State private var showsThemePicker = false
    @State private var showsSearch = false
    @State private var searchQuery = ""
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
    private let clearMediaCaches: () throws -> Void
    private let clearDiagnostics: () throws -> Void
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
        clearMediaCaches: @escaping () throws -> Void = {},
        clearDiagnostics: @escaping () throws -> Void = {},
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
        self.clearMediaCaches = clearMediaCaches
        self.clearDiagnostics = clearDiagnostics
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
        ZStack {
            VStack(spacing: 0) {
                ProjectionTopbar(
                    features: FeatureRegistry.availableFeatures(hasSettingsStore: settings != nil),
                    selection: $navigation.selection,
                    onImportFiles: onImportFiles,
                    onImportFolder: onImportFolder,
                    themeName: $themeName,
                    languageName: $languageName,
                    onTheme: { showsThemePicker = true },
                    onSearch: { showsSearch = true }
                )
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            projectionOverlay
        }
        .frame(minWidth: 900, minHeight: 620)
        .wallumePageBackground()
        .onExitCommand { dismissProjectionOverlay() }
        .onChange(of: searchQuery) { _, query in
            gallery.searchText = query
            if !query.isEmpty { navigation.selection = .gallery }
        }
    }

    @ViewBuilder
    private var projectionOverlay: some View {
        if showsThemePicker || showsSearch {
            ZStack {
                Color.black.opacity(0.56)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissProjectionOverlay)
                if showsThemePicker {
                    ProjectionThemeSheet(themeName: $themeName, dismiss: dismissProjectionOverlay)
                } else {
                    ProjectionSearchSheet(query: $searchQuery, selection: $navigation.selection, dismiss: dismissProjectionOverlay)
                }
            }
            .transition(.opacity)
            .zIndex(10)
        }
    }

    private func dismissProjectionOverlay() {
        showsThemePicker = false
        showsSearch = false
    }

    @ViewBuilder
    private var detailContent: some View {
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
                    DisplaysView(store: displays, gallery: gallery) { navigation.openGalleryForWallpaper(displayID: $0) }
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
                        clearMediaCaches: clearMediaCaches,
                        clearDiagnostics: clearDiagnostics,
                        chooseExportDestination: chooseDiagnosticsExportDestination,
                        exportDiagnostics: exportDiagnostics
                    )
                }
        case .unavailable:
            ContentUnavailableView(wallumeLocalized("功能不可用"), systemImage: FeatureRegistry.features.first { $0.id == navigation.selection }?.systemImage ?? "exclamationmark.triangle")
        }
    }
}

private struct ProjectionTopbar: View {
    let features: [WallumeFeature]
    @Binding var selection: WallumeFeatureID
    let onImportFiles: () -> Void
    let onImportFolder: () -> Void
    @Binding var themeName: String
    @Binding var languageName: String
    let onTheme: () -> Void
    let onSearch: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WallumeThemePalette {
        WallumeThemePalette.resolve(WallumeTheme.fromStoredValue(themeName), scheme: colorScheme)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            expandedBar.frame(minWidth: 1_100)
            compactBar
        }
        .padding(.leading, 24)
        .padding(.trailing, 24)
        .frame(height: 70)
        .background { HeaderDoubleClickSurface() }
        .background(palette.panel.opacity(0.96))
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    private var expandedBar: some View {
        HStack(spacing: 28) {
            HStack(spacing: 9) {
                WallumeMark(size: 28)
                Text("WALLUME").font(.caption.weight(.bold)).tracking(1.8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Wallume")

            HStack(spacing: 20) {
                ForEach(features.filter { $0.id != .settings }) { feature in
                    Button { selection = feature.id } label: {
                        Text(projectionTitle(for: feature.id))
                            .font(.caption.weight(selection == feature.id ? .semibold : .regular))
                            .foregroundStyle(selection == feature.id ? .primary : .secondary)
                            .frame(minWidth: 72, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(WallumeDesign.accent).frame(height: 2).opacity(selection == feature.id ? 1 : 0)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Button(action: onSearch) { Text("⌘K").font(.caption.monospaced()).foregroundStyle(.secondary) }
                .buttonStyle(.bordered)
                .keyboardShortcut("k", modifiers: .command)
            Button(languageName == WallumeAppLanguage.chinese.rawValue ? "EN" : "中文") { languageName = languageName == WallumeAppLanguage.chinese.rawValue ? WallumeAppLanguage.english.rawValue : WallumeAppLanguage.chinese.rawValue }.buttonStyle(.bordered)
            Button(action: onTheme) { HStack(spacing: 5) { Circle().fill(WallumeDesign.accent).frame(width: 8, height: 8); Text(wallumeLocalized(WallumeTheme.fromStoredValue(themeName).title)) } }.buttonStyle(.bordered)
            if features.contains(where: { $0.id == .settings }) {
                Button { selection = .settings } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help(wallumeLocalized("设置"))
            }
            importMenu
        }
        .animation(.easeOut(duration: 0.16), value: selection)
    }

    private var compactBar: some View {
        HStack(spacing: 12) {
            WallumeMark(size: 28)
                .accessibilityLabel("Wallume")
            HStack(spacing: 4) {
                ForEach(features.filter { $0.id != .settings }) { feature in
                    Button { selection = feature.id } label: {
                        Image(systemName: feature.systemImage)
                            .frame(width: 32, height: 32)
                            .background(selection == feature.id ? palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(projectionTitle(for: feature.id))
                }
            }
            Spacer()
            Button(action: onSearch) { Image(systemName: "magnifyingglass").frame(width: 32, height: 32) }
                .buttonStyle(.borderless)
                .keyboardShortcut("k", modifiers: .command)
                .help("搜索")
            Button(action: onTheme) { Image(systemName: "circle.lefthalf.filled").frame(width: 32, height: 32) }
                .buttonStyle(.borderless)
                .help(wallumeLocalized("主题"))
            importMenu
        }
    }

    private var importMenu: some View {
        Menu {
            Button(wallumeLocalized("导入视频"), systemImage: "film") { onImportFiles() }
            Button(wallumeLocalized("导入文件夹"), systemImage: "folder") { onImportFolder() }
        } label: {
            Label(wallumeLocalized("导入"), systemImage: "plus")
        }
        .menuStyle(.borderedButton)
        .tint(WallumeDesign.accent)
        .help(wallumeLocalized("导入视频或文件夹"))
    }

    private func projectionTitle(for id: WallumeFeatureID) -> String {
        switch id {
        case .gallery: wallumeLocalized("画面库")
        case .displays: wallumeLocalized("显示器")
        case .lockScreen: wallumeLocalized("锁屏同步")
        case .performance: wallumeLocalized("状态")
        case .settings: wallumeLocalized("设置")
        }
    }
}

private struct HeaderDoubleClickSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> HeaderDoubleClickView { HeaderDoubleClickView() }
    func updateNSView(_ nsView: HeaderDoubleClickView, context: Context) {}
}

private final class HeaderDoubleClickView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
            return
        }
        super.mouseDown(with: event)
    }
}

private struct ProjectionThemeSheet: View {
    @Binding var themeName: String
    let dismiss: () -> Void
    var body: some View { VStack(alignment: .leading, spacing: 18) { Text("选择放映氛围").font(.system(size: 28, weight: .bold, design: .serif)); Text("主题会保存到这台 Mac；默认跟随夜幕。").foregroundStyle(.secondary); ForEach(WallumeTheme.allCases) { theme in Button { themeName = theme.rawValue; dismiss() } label: { HStack { Circle().fill(theme == .dawn ? .teal : WallumeDesign.accent).frame(width: 12, height: 12); VStack(alignment: .leading) { Text(theme.title); Text(theme.detail).font(.caption).foregroundStyle(.secondary) }; Spacer(); if themeName == theme.rawValue { Image(systemName: "checkmark") } }.padding(12).background(.primary.opacity(0.05)) }.buttonStyle(.plain) } }.padding(28).frame(width: 460).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.2)) }.shadow(color: .black.opacity(0.35), radius: 32, y: 14) }
}

private struct ProjectionSearchSheet: View {
    @Binding var query: String
    @Binding var selection: WallumeFeatureID
    let dismiss: () -> Void
    var body: some View { VStack(alignment: .leading, spacing: 16) { TextField("搜索画面、显示器或操作…", text: $query).textFieldStyle(.roundedBorder); ForEach([WallumeFeatureID.gallery, .displays, .lockScreen, .performance], id: \.self) { id in Button { selection = id; dismiss() } label: { Label(id == .gallery ? "画面库" : id == .displays ? "显示器" : id == .lockScreen ? "锁屏同步" : "状态", systemImage: id == .gallery ? "square.grid.2x2" : id == .displays ? "display.2" : id == .lockScreen ? "lock" : "waveform.path.ecg").frame(maxWidth: .infinity, alignment: .leading).padding(8) }.buttonStyle(.plain) } }.padding(24).frame(width: 420).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.2)) }.shadow(color: .black.opacity(0.35), radius: 32, y: 14) }
}
