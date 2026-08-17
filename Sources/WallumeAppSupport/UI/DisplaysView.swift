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
    private let gallery: GalleryStore?
    private let onChooseWallpaper: (DisplayID) -> Void
    @State private var pickingDisplay: DisplayCardState?

    public init(
        store: DisplayFeatureStore,
        gallery: GalleryStore? = nil,
        onChooseWallpaper: @escaping (DisplayID) -> Void = { _ in }
    ) {
        self.store = store
        self.gallery = gallery
        self.onChooseWallpaper = onChooseWallpaper
    }

    public var body: some View {
        VStack(spacing: 0) {
            WallumePageHeader("显示器", subtitle: "为每块屏幕分配和预览动态壁纸") {
                playbackStatus
            }

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
                    .frame(maxWidth: WallumeDesign.contentWidth, alignment: .leading)
                    .padding(24)
                }
            }
        }
        .wallumePageBackground()
        .alert("操作失败", isPresented: Binding(
            get: { store.pageError != nil },
            set: { if !$0 { store.dismissPageError() } }
        )) {
            Button("知道了") { store.dismissPageError() }
        } message: {
            Text(store.pageError ?? "")
        }
        .sheet(item: $pickingDisplay) { card in
            if let gallery {
                DisplayMediaPicker(
                    gallery: gallery,
                    displayName: card.display.name,
                    onSelect: { item in
                        Task {
                            await store.assign(mediaID: item.id, displayIDs: [card.id])
                            if store.pageError == nil { pickingDisplay = nil }
                        }
                    }
                )
            }
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
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let media = card.media, let image = NSImage(contentsOf: media.coverURL) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Color(nsColor: .underPageBackgroundColor)
                            .overlay(Image(systemName: "display").font(.largeTitle).foregroundStyle(.secondary))
                    }
                }
                .frame(height: 210)
                .frame(maxWidth: .infinity)
                .clipped()

                HStack(spacing: 8) {
                    if card.display.isMain { WallumeStatusBadge("主显示器", systemImage: "star.fill", tint: .white) }
                    WallumeStatusBadge(
                        card.connection == .connected ? "在线" : "离线",
                        systemImage: card.connection == .connected ? "checkmark.circle.fill" : "circle.slash",
                        tint: .white
                    )
                }
                .padding(14)
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.display.name).font(.headline)
                    Text(card.wallpaperTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if let error = card.runtimeError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                if card.connection == .connected {
                    Button(card.hasAssignment ? "更换" : "选择", systemImage: "arrow.triangle.2.circlepath") {
                        if gallery != nil { pickingDisplay = card }
                        else { onChooseWallpaper(card.id) }
                    }
                } else {
                    Button("清除配置", systemImage: "trash", role: .destructive) {
                        Task { await store.clearRememberedDisplay(displayID: card.id) }
                    }
                }
            }
            .padding(16)

            if card.connection == .connected && (card.canSetPresentationMode || card.canRemoveAssignment || card.runtimeError != nil) {
                HStack {
                    if card.canSetPresentationMode {
                        Picker("显示方式", selection: modeBinding(card)) {
                            ForEach(WallpaperPresentationMode.allCases, id: \.self) { mode in
                                Text(mode.displayTitle).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    Spacer()
                    if card.runtimeError != nil {
                        Button("重试", systemImage: "arrow.clockwise") { Task { await store.retry(displayID: card.id) } }
                    }
                    if card.canRemoveAssignment {
                        Button("移除", systemImage: "minus.circle", role: .destructive) {
                            Task { await store.removeAssignment(displayID: card.id) }
                        }
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.08)) }
        .wallumeInteractiveSurface()
    }

    private func modeBinding(_ card: DisplayCardState) -> Binding<WallpaperPresentationMode> {
        Binding(
            get: { card.presentationMode },
            set: { mode in Task { await store.setPresentationMode(mode, displayID: card.id) } }
        )
    }
}

private struct DisplayMediaPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var gallery: GalleryStore
    let displayName: String
    let onSelect: (MediaItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("更换壁纸").font(.title2.weight(.semibold))
                    Text(displayName).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding(20)
            Divider()
            if gallery.items.isEmpty {
                ContentUnavailableView("还没有素材", systemImage: "film")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)], spacing: 16) {
                        ForEach(gallery.items) { item in
                            Button { onSelect(item) } label: {
                                DisplayPickerTile(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}

private struct DisplayPickerTile: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image = NSImage(contentsOf: item.thumbnailURL) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color(nsColor: .underPageBackgroundColor)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(item.displayName).lineLimit(1).font(.subheadline.weight(.semibold))
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.08)) }
    }
}
