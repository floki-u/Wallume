import AppKit
import SwiftUI
import WallumeCore

public extension WallpaperPresentationMode {
    var displayTitle: String {
        switch self {
        case .fill: "填充"
        case .fit: "完整显示"
        case .stretch: "拉伸铺满"
        }
    }
}

public struct DisplaysView: View {
    @Bindable private var store: DisplayFeatureStore
    private let onChooseWallpaper: (DisplayID) -> Void

    public init(
        store: DisplayFeatureStore,
        onChooseWallpaper: @escaping (DisplayID) -> Void = { _ in }
    ) {
        self.store = store
        self.onChooseWallpaper = onChooseWallpaper
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("显示器").font(.largeTitle.bold())
                Spacer()
                playbackStatus
            }
            .padding()

            if store.cards.isEmpty {
                ContentUnavailableView(
                    "未检测到显示器",
                    systemImage: "display.trianglebadge.exclamationmark",
                    description: Text("连接显示器后可为它设置动态壁纸")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(store.cards) { card in displayCard(card) }
                    }
                    .padding()
                }
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { store.pageError != nil },
            set: { _ in }
        )) {
            Button("知道了") {}
        } message: {
            Text(store.pageError ?? "")
        }
    }

    private var playbackStatus: some View {
        HStack {
            if !store.effectivePauseReasons.isEmpty {
                Label("已暂停", systemImage: "pause.circle.fill").foregroundStyle(.secondary)
            }
            Button(store.userPaused ? "继续播放" : "暂停播放") {
                Task { await store.setUserPaused(!store.userPaused) }
            }
        }
    }

    private func displayCard(_ card: DisplayCardState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(card.display.name).font(.title3.bold())
                if card.display.isMain { badge("主显示器", color: .blue) }
                badge(card.connection == .connected ? "在线" : "离线", color: card.connection == .connected ? .green : .secondary)
                Spacer()
                Text("\(card.display.pixelWidth) × \(card.display.pixelHeight)")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Group {
                    if let media = card.media, let image = NSImage(contentsOf: media.thumbnailURL) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        ZStack { Color.secondary.opacity(0.12); Image(systemName: "photo") }
                    }
                }
                .frame(width: 150, height: 86).clipped().clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    Text(card.media?.displayName ?? "尚未设置壁纸").font(.headline)
                    if card.connection == .connected {
                        Picker("显示方式", selection: modeBinding(card)) {
                            ForEach(WallpaperPresentationMode.allCases, id: \.self) { mode in
                                Text(mode.displayTitle).tag(mode)
                            }
                        }
                        .frame(maxWidth: 220)
                    }
                    if let error = card.runtimeError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
                Spacer()
                VStack(alignment: .trailing) {
                    if card.connection == .connected {
                        Button(card.media == nil ? "选择壁纸" : "更换壁纸") { onChooseWallpaper(card.id) }
                        if card.media != nil {
                            Button("移除", role: .destructive) { Task { await store.removeAssignment(displayID: card.id) } }
                        }
                        if card.runtimeError != nil {
                            Button("重试") { Task { await store.retry(displayID: card.id) } }
                        }
                    } else {
                        Button("清除保存的配置", role: .destructive) { Task { await store.clearRememberedDisplay(displayID: card.id) } }
                    }
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func modeBinding(_ card: DisplayCardState) -> Binding<WallpaperPresentationMode> {
        Binding(
            get: { card.presentationMode },
            set: { mode in Task { await store.setPresentationMode(mode, displayID: card.id) } }
        )
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
    }
}
