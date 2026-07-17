import SwiftUI
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
    public let errorText: String?
    public let isAwaitingDetection: Bool
    public let showsSystemWallpaperSettings: Bool
    public let canRefresh: Bool
    public let canChooseSlot: Bool
    public let canRequestEnable: Bool
    public let canRestore: Bool
    public let canRetry: Bool
    public let showsRiskConfirmation: Bool
    public let nextAction: NextAction

    public init(state: LockScreenSyncState) {
        let slots = state.probe?.availableSlots ?? []
        selectedSlotName = slots.first(where: { $0.id == state.selectedAerialID })?.displayName
            ?? state.selectedAerialID
        syncedMediaName = state.syncedMedia?.displayName
        syncedAt = state.lastSyncedAt
        syncTimeText = state.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened)
        errorText = state.lastError
        isAwaitingDetection = state.probe == nil
        showsSystemWallpaperSettings = state.probe != nil && slots.isEmpty
        canRefresh = state.capabilities.canRefreshProbe || state.phase == .unconfigured
        canChooseSlot = state.capabilities.canSelectAerialSlot
        canRequestEnable = state.capabilities.canConfirmEnable
        canRestore = state.capabilities.canDisableAndRestore
        canRetry = state.capabilities.canRetry
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
            statusText = "锁屏已与主显示器壁纸同步。"
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
    private let openSystemWallpaperSettings: () -> Void
    @State private var presentsConfirmation = false

    public init(
        store: LockScreenFeatureStore,
        openSystemWallpaperSettings: @escaping () -> Void = {}
    ) {
        self.store = store
        self.openSystemWallpaperSettings = openSystemWallpaperSettings
    }

    public var body: some View {
        let page = LockScreenPageViewState(state: store.state)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("锁屏同步").font(.largeTitle.bold())
                statusCard(page)
                probeCard(page)
                slotsCard(page)
                recoveryCard(page)
                actionRow(page)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding()
        }
        .alert("锁屏操作失败", isPresented: Binding(
            get: { store.pageError != nil },
            set: { if !$0 { store.dismissPageError() } }
        )) {
            Button("知道了") { store.dismissPageError() }
        } message: {
            Text(store.pageError ?? "")
        }
        .sheet(isPresented: $presentsConfirmation) { confirmationSheet }
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
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
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
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
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
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
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
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
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
            Text("Wallume 将只修改你选择的专用 Aerial 视频槽、对应的 Index.plist 选择节点和锁屏封面；它会在每次修改前保存恢复材料。")
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

    private func generationName(_ generation: MacOSGeneration) -> String {
        switch generation {
        case .sonoma: "Sonoma"
        case .sequoia: "Sequoia"
        case .tahoe: "Tahoe"
        case let .unsupported(version): "不支持的版本 \(version)"
        }
    }
}
