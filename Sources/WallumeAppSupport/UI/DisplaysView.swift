import AppKit
import SwiftUI
import WallumeCore

public extension WallpaperPresentationMode {
    var displayTitle: String {
        switch self {
        case .fill: wallumeLocalized("填充")
        case .fit: wallumeLocalized("完整显示")
        case .stretch: wallumeLocalized("拉伸铺满")
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
        Group {
            if store.cards.isEmpty {
                ContentUnavailableView(
                    wallumeLocalized("未检测到显示器"),
                    systemImage: "display.trianglebadge.exclamationmark",
                    description: wallumeText("连接显示器后可为它设置动态壁纸")
                )
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .bottom, spacing: 20) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("YOUR SPACE")
                                    .font(.caption2.weight(.bold))
                                    .tracking(1.6)
                                    .foregroundStyle(.tertiary)
                                wallumeText("当前空间")
                                    .font(.system(size: 30, weight: .semibold))
                                    .tracking(-0.7)
                            }
                            Spacer()
                            WallumeStatusBadge(
                                wallumeLocalized(store.cards.allSatisfy { $0.connection == .connected } ? "全部在线" : "部分离线"),
                                systemImage: store.cards.allSatisfy { $0.connection == .connected } ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                tint: store.cards.allSatisfy { $0.connection == .connected } ? WallumeDesign.success : WallumeDesign.warning
                            )
                        }

                        if let primaryCard {
                            projectionStage(primaryCard)
                        }

                        if !secondaryCards.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                wallumeText("其他显示器")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 460), spacing: 12)], spacing: 12) {
                                    ForEach(secondaryCards) { secondaryDisplayCard($0) }
                                }
                            }
                        }

                        sharedPlaybackControl
                    }
                    .frame(maxWidth: 1_280, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                }
            }
        }
        .wallumePageBackground()
        .alert(wallumeLocalized("操作失败"), isPresented: Binding(
            get: { store.pageError != nil },
            set: { if !$0 { store.dismissPageError() } }
        )) {
            Button(wallumeLocalized("知道了")) { store.dismissPageError() }
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

    private var sharedPlaybackControl: some View {
        HStack {
            Image(systemName: store.userPaused ? "play.fill" : "pause.fill")
                .frame(width: 36, height: 36)
                .background(WallumeDesign.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) { wallumeText("播放控制").font(.subheadline.weight(.semibold)); wallumeText("暂停会保留每块屏幕当前的画面与设置。").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(wallumeLocalized(store.userPaused ? "继续全部" : "暂停全部")) { Task { await store.setUserPaused(!store.userPaused) } }.buttonStyle(.bordered)
        }
        .padding(18)
        .background(WallumeDesign.surface1, in: RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous).strokeBorder(WallumeDesign.line) }
    }

    private var primaryCard: DisplayCardState? {
        store.cards.first(where: { $0.display.isMain }) ?? store.cards.first
    }

    private var secondaryCards: [DisplayCardState] {
        guard let primaryID = primaryCard?.id else { return [] }
        return store.cards.filter { $0.id != primaryID }
    }

    private func projectionStage(_ card: DisplayCardState) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                displayImage(card)
                .frame(height: 420)
                .frame(maxWidth: .infinity)
                .clipped()
                LinearGradient(colors: [.black.opacity(0.12), .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)

                HStack(spacing: 8) {
                    WallumeStatusBadge(wallumeLocalized("主显示器"), systemImage: "star.fill", tint: .white)
                    WallumeStatusBadge(
                        wallumeLocalized(card.connection == .connected ? "在线" : "离线"),
                        systemImage: card.connection == .connected ? "checkmark.circle.fill" : "circle.slash",
                        tint: .white
                    )
                }
                .padding(14)
            }

            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    wallumeText("正在投放").font(.caption.weight(.semibold)).foregroundStyle(WallumeDesign.accent)
                    Text(card.display.name).font(.title2.weight(.semibold))
                    Text(card.wallpaperTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if let error = card.runtimeError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                if card.connection == .connected {
                    Button(wallumeLocalized(card.hasAssignment ? "更换画面" : "选择画面"), systemImage: "arrow.triangle.2.circlepath") {
                        if gallery != nil { pickingDisplay = card }
                        else { onChooseWallpaper(card.id) }
                    }
                } else {
                    Button(wallumeLocalized("清除配置"), systemImage: "trash", role: .destructive) {
                        Task { await store.clearRememberedDisplay(displayID: card.id) }
                    }
                }
            }
            .padding(20)

            if card.connection == .connected && (card.canSetPresentationMode || card.canRemoveAssignment || card.runtimeError != nil) {
                HStack {
                    if card.canSetPresentationMode {
                        Picker(wallumeLocalized("显示方式"), selection: modeBinding(card)) {
                            ForEach(WallpaperPresentationMode.allCases, id: \.self) { mode in
                                Text(mode.displayTitle).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    Spacer()
                    if card.runtimeError != nil {
                        Button(wallumeLocalized("重试"), systemImage: "arrow.clockwise") { Task { await store.retry(displayID: card.id) } }
                    }
                    if card.canRemoveAssignment {
                        Button(wallumeLocalized("移除"), systemImage: "minus.circle", role: .destructive) {
                            Task { await store.removeAssignment(displayID: card.id) }
                        }
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
        }
        .background(WallumeDesign.surface1, in: RoundedRectangle(cornerRadius: WallumeDesign.largeCornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: WallumeDesign.largeCornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: WallumeDesign.largeCornerRadius, style: .continuous).strokeBorder(.white.opacity(0.1)) }
        .wallumeInteractiveSurface()
    }

    private func secondaryDisplayCard(_ card: DisplayCardState) -> some View {
        Button {
            if card.connection == .connected {
                if gallery != nil { pickingDisplay = card }
                else { onChooseWallpaper(card.id) }
            }
        } label: {
            HStack(spacing: 12) {
                displayImage(card)
                    .frame(width: 116, height: 72)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.display.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(card.wallpaperTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Label(wallumeLocalized(card.connection == .connected ? "在线" : "离线"), systemImage: card.connection == .connected ? "checkmark.circle.fill" : "circle.slash")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(card.connection == .connected ? .green : .secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(WallumeDesign.surface1, in: RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous).strokeBorder(WallumeDesign.line) }
        }
        .buttonStyle(.plain)
        .disabled(card.connection != .connected)
    }

    @ViewBuilder
    private func displayImage(_ card: DisplayCardState) -> some View {
        if let media = card.media, let image = NSImage(contentsOf: media.coverURL) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Color(nsColor: .underPageBackgroundColor)
                .overlay(Image(systemName: "display").font(.largeTitle).foregroundStyle(.secondary))
        }
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
                    wallumeText("更换壁纸").font(.title2.weight(.semibold))
                    Text(displayName).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(wallumeLocalized("关闭")) { dismiss() }
            }
            .padding(20)
            Divider()
            if gallery.items.isEmpty {
                ContentUnavailableView(wallumeLocalized("还没有素材"), systemImage: "film")
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.08)) }
    }
}
