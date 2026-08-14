import SwiftUI
import UniformTypeIdentifiers
import WallumeCore

public struct LockScreenPageViewState: Equatable, Sendable {
    public enum NextAction: Equatable, Sendable {
        case refresh
        case chooseSlot
        case confirmEnable
        case waitingForMainWallpaper
        case retry
        case restore
        case openSystemWallpaperSettings
        case none
    }

    public let statusText: String
    public let slotGuidance: String?
    public let selectedSlotName: String?
    public let syncedMediaName: String?
    public let syncedAt: Date?
    public let syncTimeText: String?
    public let staticFallbackName: String?
    public let staticFallbackImageURL: URL?
    public let errorText: String?
    public let isAwaitingDetection: Bool
    public let isTahoeCompatibilityAvailable: Bool
    public let showsSystemWallpaperSettings: Bool
    public let canRefresh: Bool
    public let canChooseSlot: Bool
    public let canRequestEnable: Bool
    public let canRestore: Bool
    public let canRetry: Bool
    public let canResynchronize: Bool
    public let canExportDiagnostics: Bool
    public let showsRiskConfirmation: Bool
    public let nextAction: NextAction

    public init(state: LockScreenSyncState) {
        let isUnsupported = state.phase == .unsupported
        let slots = state.probe?.availableSlots ?? []
        let isTahoe = state.probe?.generation == .tahoe
        selectedSlotName = isTahoe && state.selectedAerialID != nil
            ? "Wallume 专属动态资源"
            : slots.first(where: { $0.id == state.selectedAerialID })?.displayName ?? state.selectedAerialID
        syncedMediaName = state.syncedMedia?.displayName
        syncedAt = state.lastSyncedAt
        syncTimeText = state.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened)
        staticFallbackName = state.staticFallback?.displayName
        staticFallbackImageURL = state.staticFallback?.imageURL
        errorText = state.lastError
        isAwaitingDetection = state.probe == nil
        isTahoeCompatibilityAvailable = false
        showsSystemWallpaperSettings = isUnsupported || (state.probe != nil && slots.isEmpty && !isTahoeCompatibilityAvailable)
        canRefresh = !isUnsupported && (state.capabilities.canRefreshProbe || state.phase == .unconfigured)
        canChooseSlot = !isUnsupported && state.capabilities.canSelectAerialSlot
        canRequestEnable = !isUnsupported && state.capabilities.canConfirmEnable
        canRestore = !isUnsupported && state.capabilities.canDisableAndRestore
        canRetry = !isUnsupported && state.capabilities.canRetry
        let isBusy = state.phase == .probing || state.phase == .syncing || state.phase == .restoring
        canResynchronize = !isUnsupported && state.phase != .unconfigured && !isBusy
        canExportDiagnostics = true
        showsRiskConfirmation = state.capabilities.canConfirmEnable && state.selectedAerialID != nil

        switch state.phase {
        case .unconfigured, .probing:
            statusText = "正在准备锁屏同步检测。"
            slotGuidance = nil
            nextAction = .refresh
        case .readyToConfigure where slots.isEmpty:
            statusText = "尚未检测到可安全使用的动态壁纸槽。"
            slotGuidance = "请先在系统壁纸设置中下载并选择动态壁纸，然后返回刷新检测。"
            nextAction = .openSystemWallpaperSettings
        case .readyToConfigure where state.selectedAerialID == nil:
            statusText = "请选择一个专用 Aerial 槽；选择本身不会启用同步。"
            slotGuidance = "选择后仍需查看风险说明并明确确认，Wallume 不会自动启用。"
            nextAction = .chooseSlot
        case .readyToConfigure:
            statusText = "已选择专用 Aerial 槽，等待你的风险确认。"
            slotGuidance = "确认后才会保存启用意图，并在主显示器有可用壁纸时同步。"
            nextAction = .confirmEnable
        case .waitingForMainWallpaper:
            statusText = "等待主显示器的可用壁纸；当前不会写入或恢复系统文件。"
            slotGuidance = nil
            nextAction = .waitingForMainWallpaper
        case .syncing:
            statusText = "正在同步锁屏，请保持 Wallume 运行。"
            slotGuidance = nil
            nextAction = .none
        case .synced:
            statusText = "已写入系统锁屏注册；请锁屏确认视频已播放。"
            slotGuidance = nil
            nextAction = canRestore ? .restore : .none
        case .restoring:
            statusText = "正在恢复系统锁屏壁纸，请勿关闭应用。"
            slotGuidance = nil
            nextAction = .none
        case .needsRepair:
            statusText = "锁屏同步已安全停止，桌面壁纸不受影响。"
            slotGuidance = "请先恢复系统壁纸；若恢复不可用，请重新检测后重试。"
            nextAction = canRestore ? .restore : (canRetry ? .retry : .refresh)
        case .unsupported:
            statusText = "当前系统环境不支持由 Wallume 写入锁屏。"
            slotGuidance = "可打开系统壁纸设置使用 macOS 的内置选项。"
            nextAction = .openSystemWallpaperSettings
        }
    }
}

public struct LockScreenView: View {
    @Bindable private var store: LockScreenFeatureStore
    private let nativeProvider: NativeWallpaperProviderStore?
    private let openSystemWallpaperSettings: () -> Void
    private let revealStaticFallback: (URL) -> Void
    @State private var presentsConfirmation = false
    @State private var presentsDiagnosticExporter = false
    @State private var diagnosticDocument: LockScreenDiagnosticDocument?

    public init(
        store: LockScreenFeatureStore,
        nativeProvider: NativeWallpaperProviderStore? = nil,
        openSystemWallpaperSettings: @escaping () -> Void = {},
        revealStaticFallback: @escaping (URL) -> Void = { _ in }
    ) {
        self.store = store
        self.nativeProvider = nativeProvider
        self.openSystemWallpaperSettings = openSystemWallpaperSettings
        self.revealStaticFallback = revealStaticFallback
    }

    public var body: some View {
        if let nativeProvider {
            nativeProviderBody(nativeProvider)
        } else {
            legacyLockScreenBody
        }
    }

    private func nativeProviderBody(_ provider: NativeWallpaperProviderStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WallumePageHeader("锁屏与桌面", subtitle: "原生动态壁纸通过 macOS 同时应用到桌面和锁屏") {
                    WallumeStatusBadge(
                        nativeShortStatus(provider.status),
                        systemImage: nativeStatusIcon(provider.status),
                        tint: nativeStatusTint(provider.status)
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(nativeStatusText(provider.status)).font(.title3.weight(.semibold))
                    Text("Wallume 只准备属于自己的视频素材。选择和应用始终由系统“壁纸”完成，不会直接修改 macOS 的壁纸数据库。")
                        .foregroundStyle(.secondary)
                    if let media = provider.media {
                        Label(media.displayName, systemImage: "film")
                            .font(.subheadline.weight(.medium))
                    }
                }
                .wallumePanel()

                VStack(alignment: .leading, spacing: 0) {
                    nativeStep(
                        number: "1",
                        title: "准备视频",
                        detail: provider.media == nil ? "先在显示器页为主显示器分配一个视频。" : "创建供系统壁纸提供者读取的视频与静态封面。",
                        actionTitle: "准备当前视频",
                        actionIcon: "arrow.down.circle",
                        isEnabled: provider.media != nil && provider.status != .activeInSystem
                    ) { Task { await provider.prepareCurrentMedia() } }

                    nativeStep(
                        number: "2",
                        title: "在系统中选择",
                        detail: "打开系统设置，在 Wallume 分类中选择刚准备的视频。",
                        actionTitle: "打开系统壁纸设置",
                        actionIcon: "gearshape",
                        isEnabled: provider.deployment != nil
                    ) { openSystemWallpaperSettings() }

                    nativeStep(
                        number: "3",
                        title: "确认已生效",
                        detail: provider.status == .activeInSystem ? "系统已报告 Wallume 视频正在使用。" : "选择完成后检查状态；桌面和锁屏会由 macOS 接管。",
                        actionTitle: "检查状态",
                        actionIcon: "arrow.clockwise",
                        isEnabled: provider.deployment != nil
                    ) { Task { await provider.refreshSystemSelection() } }
                }
                .clipShape(RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1))
                }
                .padding(.vertical, 24)

                if let imageURL = provider.media?.coverURL {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("动态视频无法加载？").font(.headline)
                            Text("可以改用当前视频生成的静态封面；Wallume 不会替你自动更换系统壁纸。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Button("查看封面", systemImage: "eye") { revealStaticFallback(imageURL) }
                    }
                    .wallumeCard()
                }

                if provider.deployment != nil {
                    DisclosureGroup("重置 Provider 资源") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("先在系统壁纸设置中选择其他壁纸，再确认重置。你的 Wallume 媒体库不会被删除。")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("确认系统已重置") { Task { await provider.confirmSystemReset() } }
                                Button("清理资源", systemImage: "trash", role: .destructive) {
                                    Task { await provider.cleanupAfterReset() }
                                }
                                .disabled(provider.status != .resetConfirmed)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline)
                }
            }
            .frame(maxWidth: WallumeDesign.contentWidth, alignment: .leading)
            .padding(24)
        }
        .wallumePageBackground()
    }

    private func nativeStep(
        number: String,
        title: String,
        detail: String,
        actionTitle: String,
        actionIcon: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(WallumeDesign.accent)
                .frame(width: 24, height: 24)
                .background(WallumeDesign.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button(actionTitle, systemImage: actionIcon, action: action)
                .labelStyle(.titleAndIcon)
                .disabled(!isEnabled)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var legacyLockScreenBody: some View {
        let page = LockScreenPageViewState(state: store.state)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WallumePageHeader("锁屏同步", subtitle: "仅在系统安全支持时写入锁屏配置") { EmptyView() }
                statusCard(page)
                probeCard(page)
                slotsCard(page)
                recoveryCard(page)
                staticFallbackCard(page)
                actionRow(page)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding()
        }
        .wallumePageBackground()
        .alert("锁屏操作失败", isPresented: Binding(
            get: { store.pageError != nil },
            set: { if !$0 { store.dismissPageError() } }
        )) {
            Button("知道了") { store.dismissPageError() }
        } message: {
            Text(store.pageError ?? "")
        }
        .sheet(isPresented: $presentsConfirmation) { confirmationSheet }
        .fileExporter(
            isPresented: $presentsDiagnosticExporter,
            document: diagnosticDocument,
            contentType: .json,
            defaultFilename: "Wallume-lock-screen-diagnostics"
        ) { result in
            if case let .failure(error) = result {
                store.reportPageError(error.localizedDescription)
            }
        }
    }

    private func statusCard(_ page: LockScreenPageViewState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(page.statusText, systemImage: statusIcon)
                .font(.headline)
            if let media = page.syncedMediaName {
                Text("当前锁屏媒体：\(media)")
            }
            if let time = page.syncTimeText {
                Text("状态更新时间：\(time)").foregroundStyle(.secondary)
            }
            if let error = page.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if let guidance = page.slotGuidance {
                Text(guidance).foregroundStyle(.secondary)
            }
        }
        .wallumeCard()
    }

    private func probeCard(_ page: LockScreenPageViewState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("环境检测").font(.title3.bold())
            if let probe = store.state.probe {
                Text("macOS：\(generationName(probe.generation))")
                Text("写入权限：\(probe.writesPermitted ? "可用" : "不可用")")
                Text("Aerial 清单：\(probe.manifestExists ? "已找到" : "未找到")；壁纸索引：\(probe.indexExists ? "已找到" : "未找到")")
                if !probe.foreignBackupNames.isEmpty {
                    Text("检测到外部备份冲突，不能继续写入。").foregroundStyle(.red)
                }
            } else {
                Text("尚未完成检测，请先刷新。 ").foregroundStyle(.secondary)
            }
            if page.canRefresh {
                Button("刷新检测") { Task { await store.refreshProbe() } }
            }
        }
        .wallumeCard()
    }

    private func slotsCard(_ page: LockScreenPageViewState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("专用 Aerial 槽").font(.title3.bold())
            if let selected = page.selectedSlotName {
                Text("已选择：\(selected)")
            }
            let slots = store.state.probe?.availableSlots ?? []
            if page.isAwaitingDetection {
                Text("等待检测完成后再显示可用的 Aerial 槽。")
                    .foregroundStyle(.secondary)
            } else if page.showsSystemWallpaperSettings {
                Button("打开系统壁纸设置") { openSystemWallpaperSettings() }
            } else {
                ForEach(slots, id: \.id) { slot in
                    Button {
                        Task { await store.selectAerialSlot(slot.id) }
                    } label: {
                        HStack {
                            Image(systemName: store.state.selectedAerialID == slot.id ? "checkmark.circle.fill" : "circle")
                            Text(slot.displayName)
                            Spacer()
                        }
                    }
                    .disabled(!page.canChooseSlot || store.state.selectedAerialID == slot.id)
                }
            }
            if page.canRequestEnable {
                Button("查看启用确认") { presentsConfirmation = true }
            }
        }
        .wallumeCard()
    }

    private func recoveryCard(_ page: LockScreenPageViewState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("备份与恢复").font(.title3.bold())
            Text("启用后，Wallume 会为专用视频槽、锁屏封面和壁纸索引保留恢复材料。关闭同步或切换媒体时，会先验证恢复完成。")
                .foregroundStyle(.secondary)
            if store.state.activeTransactionID != nil {
                Text("当前存在可恢复的锁屏事务。").foregroundStyle(.secondary)
            }
            if page.canRestore {
                Button("恢复系统锁屏壁纸", role: .destructive) {
                    Task { await store.disableAndRestore() }
                }
            }
            if page.canRetry {
                Button("重新检测并重试") { Task { await store.retry() } }
            }
            if page.canResynchronize {
                Button("重新同步") { Task { await store.resynchronize() } }
            }
            if page.canExportDiagnostics {
                Button("导出本地诊断") {
                    do {
                        diagnosticDocument = LockScreenDiagnosticDocument(
                            data: try store.makeDiagnosticExportData()
                        )
                        presentsDiagnosticExporter = true
                    } catch {
                        store.reportPageError(error.localizedDescription)
                    }
                }
            }
        }
        .wallumeCard()
    }

    @ViewBuilder
    private func staticFallbackCard(_ page: LockScreenPageViewState) -> some View {
        if (store.state.phase == .unsupported || store.state.phase == .needsRepair),
           let imageURL = page.staticFallbackImageURL {
            VStack(alignment: .leading, spacing: 8) {
                Text("静态图片降级").font(.title3.bold())
                Text("动态锁屏目前无法安全设置。Wallume 已为当前视频生成静态封面；你可以在系统壁纸设置中手动选择它，也可以先恢复或重置后再尝试动态锁屏。")
                    .foregroundStyle(.secondary)
                if let name = page.staticFallbackName {
                    Text("封面来源：\(name)").foregroundStyle(.secondary)
                }
                HStack {
                    Button("显示静态封面") { revealStaticFallback(imageURL) }
                    Button("打开系统壁纸设置") { openSystemWallpaperSettings() }
                }
            }
            .wallumeCard()
        }
    }

    private func actionRow(_ page: LockScreenPageViewState) -> some View {
        HStack {
            if page.nextAction == .refresh {
                Button("开始检测") { Task { await store.refreshProbe() } }
            } else if page.nextAction == .openSystemWallpaperSettings {
                Button("打开系统壁纸设置") { openSystemWallpaperSettings() }
            }
            Spacer()
            Text("选择槽不会启用同步；必须在确认页明确同意。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var confirmationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认启用锁屏同步").font(.title2.bold())
            Text("Wallume 会在每次修改前保存恢复材料。")
            Text("启用后，锁屏会跟随主显示器的当前壁纸。切换媒体或关闭同步时，Wallume 会先恢复此前的系统内容。")
                .foregroundStyle(.secondary)
            HStack {
                Button("取消") { presentsConfirmation = false }
                Spacer()
                Button("确认启用") {
                    presentsConfirmation = false
                    Task { await store.confirmEnable() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var statusIcon: String {
        switch store.state.phase {
        case .synced: "checkmark.circle.fill"
        case .needsRepair, .unsupported: "exclamationmark.triangle.fill"
        case .syncing, .restoring, .probing: "arrow.triangle.2.circlepath"
        default: "lock.display"
        }
    }

    private func nativeStatusText(_ status: NativeWallpaperProviderStatus) -> String {
        switch status {
        case .unavailable: "当前 macOS 版本不支持 Wallume 原生动态锁屏。"
        case .needsMedia: "请先在主显示器选择一个已导入的视频。"
        case .readyToPrepare: "当前视频可准备为系统动态壁纸。"
        case .preparedForSystemSelection: "视频已准备好，等待你在系统设置中选择。"
        case .activeInSystem: "系统已选中 Wallume 动态壁纸，桌面和锁屏由 macOS 原生播放。"
        case .resetConfirmed: "系统重置已确认，现在可以清理 Wallume 的提供者资源。"
        case let .failure(message): message
        }
    }

    private func nativeShortStatus(_ status: NativeWallpaperProviderStatus) -> String {
        switch status {
        case .unavailable: "不可用"
        case .needsMedia: "需要视频"
        case .readyToPrepare: "可以准备"
        case .preparedForSystemSelection: "等待系统选择"
        case .activeInSystem: "已生效"
        case .resetConfirmed: "可以清理"
        case .failure: "需要处理"
        }
    }

    private func nativeStatusTint(_ status: NativeWallpaperProviderStatus) -> Color {
        switch status {
        case .activeInSystem: .green
        case .failure, .unavailable: .red
        case .preparedForSystemSelection, .readyToPrepare: WallumeDesign.accent
        case .needsMedia, .resetConfirmed: .secondary
        }
    }

    private func nativeStatusIcon(_ status: NativeWallpaperProviderStatus) -> String {
        switch status {
        case .activeInSystem: "checkmark.circle.fill"
        case .failure, .unavailable: "exclamationmark.triangle.fill"
        case .preparedForSystemSelection: "gearshape.2"
        default: "lock.display"
        }
    }

    private func generationName(_ generation: MacOSGeneration) -> String {
        switch generation {
        case .sonoma: "Sonoma"
        case .sequoia: "Sequoia"
        case .tahoe: "Tahoe"
        case let .unsupported(version): "不支持的版本 \(version)"
        }
    }
}

private struct LockScreenDiagnosticDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
