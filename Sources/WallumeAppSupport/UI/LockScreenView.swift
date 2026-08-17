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
    @State private var presentsProviderReset = false

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
            VStack(alignment: .leading, spacing: 18) {
                WallumePageHeader("锁屏", subtitle: "将当前素材用于锁屏") {
                    WallumeStatusBadge(
                        nativeShortStatus(provider.status),
                        systemImage: nativeStatusIcon(provider.status),
                        tint: nativeStatusTint(provider.status)
                    )
                }

                nativeCanvas(provider)

                nativePrimaryAction(provider)

                if case .failure = provider.status, let imageURL = provider.media?.coverURL {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("锁屏未能启用").font(.headline)
                            Text("你可以先使用当前素材的静态封面，或重置后再试。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Button("查看封面", systemImage: "eye") { revealStaticFallback(imageURL) }
                    }
                    .wallumeCard()
                }

                if provider.deployment != nil {
                    Divider()
                    Button("管理锁屏资源", systemImage: "arrow.counterclockwise") {
                        presentsProviderReset = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: WallumeDesign.contentWidth, alignment: .leading)
            .padding(24)
        }
        .wallumePageBackground()
        .alert("无法打开系统壁纸设置", isPresented: Binding(
            get: { store.pageError != nil },
            set: { if !$0 { store.dismissPageError() } }
        )) {
            Button("知道了") { store.dismissPageError() }
        } message: {
            Text(store.pageError ?? "")
        }
        .sheet(isPresented: $presentsProviderReset) {
            providerResetSheet(provider)
        }
    }

    private func providerResetSheet(_ provider: NativeWallpaperProviderStore) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("管理锁屏资源").font(.title2.weight(.bold))
            Text("如需移除系统设置中的 Wallume 项目，先在系统壁纸设置中选择其他壁纸。Wallume 会检查系统状态后再清理锁屏副本，素材库不会被删除。")
                .foregroundStyle(.secondary)
            resetStatusMessage(provider.status)
            HStack {
                Button("取消") { presentsProviderReset = false }
                Spacer()
                Button("检查系统状态", systemImage: "checkmark.shield") {
                    Task { await provider.confirmSystemReset() }
                }
                Button("清理锁屏副本", systemImage: "trash", role: .destructive) {
                    Task {
                        await provider.cleanupAfterReset()
                        if case .failure = provider.status {
                            return
                        }
                        presentsProviderReset = false
                    }
                }
                .disabled(provider.status != .resetConfirmed)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder
    private func resetStatusMessage(_ status: NativeWallpaperProviderStatus) -> some View {
        switch status {
        case .resetConfirmed:
            Label("系统已不再使用 Wallume 素材，可以清理锁屏副本。", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        default:
            Label("选择其他壁纸后，点“检查系统状态”继续。", systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func nativeCanvas(_ provider: NativeWallpaperProviderStore) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let media = provider.media, let image = NSImage(contentsOf: media.coverURL) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color(nsColor: .underPageBackgroundColor)
                        .overlay(Image(systemName: "lock.display").font(.system(size: 42)).foregroundStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 210)
            .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text(nativeStatusTitle(provider.status))
                    .font(.title2.weight(.bold))
                Text(nativeStatusDetail(provider.status))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let media = provider.media {
                    Label(media.displayName, systemImage: "film")
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.08)) }
        .wallumeInteractiveSurface()
    }

    @ViewBuilder
    private func nativePrimaryAction(_ provider: NativeWallpaperProviderStore) -> some View {
        switch provider.status {
        case .needsMedia:
            Label("先在显示器页选择素材", systemImage: "display")
                .foregroundStyle(.secondary)
                .wallumeCard()
        case .readyToPrepare:
            Button("用于锁屏", systemImage: "lock") {
                Task {
                    await provider.prepareCurrentMedia()
                    if provider.status == .preparedForSystemSelection { openSystemWallpaperSettings() }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .preparedForSystemSelection:
            Button("在系统设置中启用", systemImage: "gearshape") { openSystemWallpaperSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .systemSelectionNeedsUpdate:
            Button("更新锁屏素材", systemImage: "arrow.triangle.2.circlepath") {
                Task {
                    await provider.prepareCurrentMedia()
                    if provider.status == .preparedForSystemSelection { openSystemWallpaperSettings() }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .activeInSystem:
            HStack {
                Label("锁屏已启用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") { Task { await provider.refreshSystemSelection() } }
            }
            .wallumeCard()
        case .resetConfirmed:
            Button("清理锁屏资源", systemImage: "trash", role: .destructive) { Task { await provider.cleanupAfterReset() } }
        case .unavailable, .failure:
            EmptyView()
        }
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

    private func nativeStatusTitle(_ status: NativeWallpaperProviderStatus) -> String {
        switch status {
        case .unavailable: "此版本暂不支持锁屏"
        case .needsMedia: "还没有可用于锁屏的素材"
        case .readyToPrepare: "当前素材可用于锁屏"
        case .preparedForSystemSelection: "等待你在系统设置中启用"
        case .systemSelectionNeedsUpdate: "锁屏仍在使用另一段素材"
        case .activeInSystem: "锁屏已启用"
        case .resetConfirmed: "可以清理锁屏资源"
        case let .failure(message): message
        }
    }

    private func nativeStatusDetail(_ status: NativeWallpaperProviderStatus) -> String {
        switch status {
        case .unavailable: "可在系统设置中使用其他壁纸。"
        case .needsMedia: "先为主显示器应用一个素材。"
        case .readyToPrepare: "启用后，当前素材会同时用于桌面与锁屏。"
        case .preparedForSystemSelection: "系统设置已打开后，在 Wallume 分类中选择当前素材。"
        case .systemSelectionNeedsUpdate: "已选择的新素材可立即用于桌面；更新锁屏后，在系统设置中选择它即可完成切换。"
        case .activeInSystem: "当前素材正在用于桌面和锁屏。"
        case .resetConfirmed: "清理不会删除你的素材库。"
        case .failure: "可使用静态封面，或重置后再试。"
        }
    }

    private func nativeShortStatus(_ status: NativeWallpaperProviderStatus) -> String {
        switch status {
        case .unavailable: "不可用"
        case .needsMedia: "需要视频"
        case .readyToPrepare: "可以准备"
        case .preparedForSystemSelection: "等待系统选择"
        case .systemSelectionNeedsUpdate: "需要更新"
        case .activeInSystem: "已生效"
        case .resetConfirmed: "可以清理"
        case .failure: "需要处理"
        }
    }

    private func nativeStatusTint(_ status: NativeWallpaperProviderStatus) -> Color {
        switch status {
        case .activeInSystem: .green
        case .failure, .unavailable: .red
        case .preparedForSystemSelection, .readyToPrepare, .systemSelectionNeedsUpdate: WallumeDesign.accent
        case .needsMedia, .resetConfirmed: .secondary
        }
    }

    private func nativeStatusIcon(_ status: NativeWallpaperProviderStatus) -> String {
        switch status {
        case .activeInSystem: "checkmark.circle.fill"
        case .failure, .unavailable: "exclamationmark.triangle.fill"
        case .preparedForSystemSelection, .systemSelectionNeedsUpdate: "gearshape.2"
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
