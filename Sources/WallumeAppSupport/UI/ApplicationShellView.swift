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
        !pauseReasons.isEmpty && !userPaused ? wallumeLocalized("已因系统状态暂停") : nil
    }
    public var actionTitle: String { wallumeLocalized(userPaused ? "继续播放" : "暂停播放") }
}

public struct ApplicationShellView: View {
    @Bindable private var navigation: ApplicationNavigation
    @AppStorage("wallume.theme") private var themeName = WallumeTheme.nocturne.rawValue
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
            HStack(spacing: 0) {
                ProjectionSidebar(
                    features: FeatureRegistry.availableFeatures(hasSettingsStore: settings != nil),
                    selection: $navigation.selection,
                    isRuntimeActive: displays?.cards.contains(where: { $0.hasAssignment && $0.connection == .connected }) ?? false,
                    runtimeLabel: displays?.cards.first(where: { $0.hasAssignment }).flatMap { card in
                        card.media.map { "\($0.displayName) · \(card.display.name)" }
                    }
                )
                VStack(spacing: 0) {
                    ProjectionTopbar(
                        selection: $navigation.selection,
                        onImportFiles: onImportFiles,
                        onImportFolder: onImportFolder,
                        themeName: $themeName,
                        onTheme: { showsThemePicker = true },
                        onSearch: { showsSearch = true }
                    )
                    detailContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
                Color.black.opacity(0.64)
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

private struct ProjectionSidebar: View {
    let features: [WallumeFeature]
    @Binding var selection: WallumeFeatureID
    let isRuntimeActive: Bool
    let runtimeLabel: String?
    @AppStorage("wallume.theme") private var themeName = WallumeTheme.nocturne.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WallumeThemePalette {
        WallumeThemePalette.resolve(WallumeTheme.fromStoredValue(themeName), scheme: colorScheme)
    }

    var body: some View {
        VStack(spacing: 12) {
            WallumeMark(size: 32)
                .padding(.top, 12)
                .accessibilityLabel("Wallume")

            VStack(spacing: 6) {
                ForEach(features.filter { $0.id != .settings }) { feature in
                    navigationButton(feature)
                }
            }
            .padding(.top, 20)

            Spacer(minLength: 12)

            HStack(spacing: 0) {
                Circle()
                    .fill(isRuntimeActive ? WallumeDesign.success : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                    .shadow(color: isRuntimeActive ? WallumeDesign.success.opacity(0.45) : .clear, radius: 4)
            }
            .frame(width: 44, height: 32)
            .help(
                runtimeLabel.map { wallumeLocalized("正在放映：%@", $0) }
                    ?? wallumeLocalized(isRuntimeActive ? "壁纸运行时在线" : "等待画面")
            )

            if let settings = features.first(where: { $0.id == .settings }) {
                navigationButton(settings)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(width: WallumeDesign.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(palette.panel.opacity(0.98))
        .overlay(alignment: .trailing) { Rectangle().fill(palette.line).frame(width: 1) }
    }

    private func navigationButton(_ feature: WallumeFeature) -> some View {
        let isSelected = selection == feature.id
        return Button { selection = feature.id } label: {
            Image(systemName: sidebarImage(for: feature.id))
                .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 44, height: 44)
                .background(
                    isSelected ? palette.accent.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous)
                )
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: 2, height: 18)
                        .offset(x: -8)
                        .opacity(isSelected ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(projectionTitle(for: feature.id))
        .accessibilityLabel(projectionTitle(for: feature.id))
    }

    private func sidebarImage(for id: WallumeFeatureID) -> String {
        switch id {
        case .gallery: "square.grid.2x2"
        case .displays: "display"
        case .lockScreen: "lock"
        case .performance: "waveform.path.ecg"
        case .settings: "gearshape"
        }
    }
}

private struct ProjectionTopbar: View {
    @Binding var selection: WallumeFeatureID
    let onImportFiles: () -> Void
    let onImportFolder: () -> Void
    @Binding var themeName: String
    let onTheme: () -> Void
    let onSearch: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WallumeThemePalette {
        WallumeThemePalette.resolve(WallumeTheme.fromStoredValue(themeName), scheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(projectionTitle(for: selection))
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(projectionSubtitle(for: selection))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            Button(action: onSearch) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text(wallumeLocalized("搜索"))
                    Text("⌘K")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(WallumeDesign.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line) }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)

            Button(action: onTheme) {
                Image(systemName: "circle.lefthalf.filled")
                    .frame(width: 40, height: 40)
                    .background(WallumeDesign.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line) }
            }
            .buttonStyle(.plain)
            .help(wallumeLocalized("主题"))

            if selection == .gallery {
                importMenu
            }
        }
        .padding(.horizontal, 24)
        .frame(height: WallumeDesign.toolbarHeight)
        .background { HeaderDoubleClickSurface() }
        .background(palette.panel.opacity(0.96))
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    private var importMenu: some View {
        Menu {
            Button(wallumeLocalized("导入视频"), systemImage: "film") { onImportFiles() }
            Button(wallumeLocalized("导入文件夹"), systemImage: "folder") { onImportFolder() }
        } label: {
            Label(wallumeLocalized("导入"), systemImage: "plus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.black.opacity(0.78))
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(palette.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(wallumeLocalized("导入视频或文件夹"))
    }

    private func projectionSubtitle(for id: WallumeFeatureID) -> String {
        switch id {
        case .gallery: wallumeLocalized("本地视频不会上传")
        case .displays: wallumeLocalized("每块屏幕拥有自己的画面")
        case .lockScreen: wallumeLocalized("最终选择始终由 macOS 确认")
        case .performance: wallumeLocalized("安静运行，只在需要时出现")
        case .settings: wallumeLocalized("偏好保存在这台 Mac")
        }
    }
}

private func projectionTitle(for id: WallumeFeatureID) -> String {
    switch id {
    case .gallery: wallumeLocalized("画面库")
    case .displays: wallumeLocalized("显示器")
    case .lockScreen: wallumeLocalized("锁屏同步")
    case .performance: wallumeLocalized("运行状态")
    case .settings: wallumeLocalized("设置")
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
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                wallumeText("选择外观").font(.title2.weight(.semibold))
                wallumeText("保持同一套放映界面，只切换明暗环境。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach([WallumeTheme.nocturne, .dawn, .system]) { theme in
                Button {
                    themeName = theme.rawValue
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(theme == .dawn ? Color.white : theme == .system ? Color.secondary : WallumeDesign.canvas)
                            .frame(width: 28, height: 28)
                            .overlay { Circle().strokeBorder(.white.opacity(0.16)) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(theme.title).font(.subheadline.weight(.semibold))
                            Text(theme.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if themeName == theme.rawValue {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(WallumeDesign.accent)
                        }
                    }
                    .padding(12)
                    .background(WallumeDesign.surface1, in: RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous).strokeBorder(WallumeDesign.line) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(WallumeDesign.surface2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WallumeDesign.lineStrong) }
        .shadow(color: .black.opacity(0.34), radius: 28, y: 12)
    }
}

private struct ProjectionSearchSheet: View {
    @Binding var query: String
    @Binding var selection: WallumeFeatureID
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(wallumeLocalized("搜索画面、显示器或操作…"), text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(WallumeDesign.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WallumeDesign.lineStrong) }

            ForEach([WallumeFeatureID.gallery, .displays, .lockScreen, .performance], id: \.self) { id in
                Button {
                    selection = id
                    dismiss()
                } label: {
                    Label(projectionTitle(for: id), systemImage: id == .gallery ? "square.grid.2x2" : id == .displays ? "display" : id == .lockScreen ? "lock" : "waveform.path.ecg")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(selection == id ? WallumeDesign.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(WallumeDesign.surface2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WallumeDesign.lineStrong) }
        .shadow(color: .black.opacity(0.34), radius: 28, y: 12)
    }
}
