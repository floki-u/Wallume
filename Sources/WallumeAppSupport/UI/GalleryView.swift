import AppKit
import SwiftUI
import WallumeCore

public struct GalleryView: View {
    @Bindable private var gallery: GalleryStore
    private let tasks: ImportTaskStore
    private let displays: DisplayFeatureStore?
    private let preferredAssignmentDisplayID: DisplayID?
    private let onAssignmentFlowFinished: () -> Void
    private let onImportFiles: () -> Void
    private let onImportFolder: () -> Void
    private let onDrop: ([URL]) -> Void
    @State private var assignmentItem: MediaItem?
    @State private var pendingAssignmentItem: MediaItem?
    @State private var carouselSelection: UUID?
    @State private var isAutoCycling = true

    public init(gallery: GalleryStore, tasks: ImportTaskStore, displays: DisplayFeatureStore? = nil, preferredAssignmentDisplayID: DisplayID? = nil, onAssignmentFlowFinished: @escaping () -> Void = {}, onImportFiles: @escaping () -> Void, onImportFolder: @escaping () -> Void, onDrop: @escaping ([URL]) -> Void) {
        self.gallery = gallery
        self.tasks = tasks
        self.displays = displays
        self.preferredAssignmentDisplayID = preferredAssignmentDisplayID
        self.onAssignmentFlowFinished = onAssignmentFlowFinished
        self.onImportFiles = onImportFiles
        self.onImportFolder = onImportFolder
        self.onDrop = onDrop
    }

    public var body: some View {
        Group {
            if let error = gallery.loadError {
                ContentUnavailableView(wallumeLocalized("无法读取图库"), systemImage: "exclamationmark.triangle", description: Text(error))
            } else if gallery.items.isEmpty {
                VStack(spacing: 20) {
                    ContentUnavailableView(
                        wallumeLocalized("导入第一段画面"),
                        systemImage: "photo.on.rectangle.angled",
                        description: wallumeText("支持 PNG、JPG、HEIC、MOV 和 MP4；也可以选择文件夹递归导入。")
                    )
                    HStack(spacing: 12) {
                        Button(wallumeLocalized("导入图片或视频"), systemImage: "photo.on.rectangle") { onImportFiles() }
                            .buttonStyle(.borderedProminent)
                            .tint(WallumeDesign.accent)
                        Button(wallumeLocalized("导入文件夹"), systemImage: "folder") { onImportFolder() }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                    projectionLibrary
                    if gallery.filteredItems.isEmpty {
                        ContentUnavailableView(wallumeLocalized("没有匹配的视频"), systemImage: "magnifyingglass", description: wallumeText("尝试其他关键词。"))
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        projectionFilmstrip
                    }
                    }
                }
            }
        }
        .wallumePageBackground()
        .animation(.easeInOut(duration: 0.2), value: gallery.filteredItems.map(\.id))
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return !urls.isEmpty
        }
        .safeAreaInset(edge: .bottom) {
            if tasks.snapshot.isActive || tasks.snapshot.summary.total > 0 || !tasks.snapshot.warnings.isEmpty {
                ImportTaskDrawer(store: tasks)
            }
        }
        .sheet(item: $gallery.selectedItem, onDismiss: presentPendingAssignmentIfNeeded) { item in detailSheet(item) }
        .sheet(item: $assignmentItem) { item in assignmentSheet(item) }
        .alert(wallumeLocalized("媒体正在使用中"), isPresented: Binding(
            get: { gallery.deletionBlock != nil },
            set: { if !$0 { gallery.dismissDeletionBlock() } }
        )) {
            Button(wallumeLocalized("知道了")) { gallery.dismissDeletionBlock() }
        } message: {
            Text(wallumeLocalized("请先在显示器页面更换壁纸：%@", gallery.deletionBlock?.displays.map(\.name).joined(separator: "、") ?? ""))
        }
        .onAppear { ensureCarouselSelection() }
        .onChange(of: gallery.filteredItems.map(\.id)) { _, _ in ensureCarouselSelection() }
        .task(id: carouselSelection) {
            guard isAutoCycling, gallery.filteredItems.count > 1 else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, isAutoCycling else { return }
            nextCarouselItem()
        }
    }

    private var playbackSummary: (mediaName: String, displayName: String)? {
        guard let card = displays?.cards.first(where: { $0.hasAssignment }), let media = card.media else { return nil }
        return (media.displayName, card.display.name)
    }

    private var projectionLibrary: some View {
        projectionFeature
        .frame(maxWidth: 1_620)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    private var projectionFeature: some View {
        ZStack(alignment: .bottomTrailing) {
            if let item = carouselItem {
                GalleryCarouselSlide(item: item, displayName: playbackSummary?.displayName)
            }

            HStack(spacing: 8) {
                carouselButton("chevron.left", action: previousCarouselItem)
                Button { isAutoCycling.toggle() } label: {
                    Image(systemName: isAutoCycling ? "pause.fill" : "play.fill")
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.58), in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.14)) }
                }
                .buttonStyle(.plain)
                .help(wallumeLocalized(isAutoCycling ? "暂停轮播" : "自动轮播"))
                carouselButton("chevron.right", action: nextCarouselItem)
                Button { if let item = carouselItem { gallery.selectedItem = item } } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 48, height: 48)
                        .background(.white, in: Circle())
                        .foregroundStyle(.black.opacity(0.78))
                }
                .buttonStyle(.plain)
                .help(wallumeLocalized("预览当前画面"))
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(minHeight: 360)
    }

    private var projectionFilmstrip: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    wallumeText("所有画面").font(.headline)
                    Text(wallumeLocalized("%@ 段本地视频 · 选择一段画面进行预览或投放", gallery.filteredItems.count.formatted()))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "square.grid.2x2")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(WallumeDesign.surface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .padding(.horizontal, 24)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                ForEach(gallery.filteredItems) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.22)) { carouselSelection = item.id }
                    } label: { ProjectionFilmstripTile(item: item, isSelected: item.id == carouselSelection) }
                    .buttonStyle(.plain)
                }
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.top, 26)
        .padding(.bottom, 32)
    }

    private var carouselItem: MediaItem? {
        gallery.filteredItems.first { $0.id == carouselSelection } ?? gallery.filteredItems.first
    }

    private func carouselButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.58), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.14)) }
        }
        .buttonStyle(.plain)
        .help(wallumeLocalized(systemImage == "chevron.left" ? "上一段视频" : "下一段视频"))
    }

    private func ensureCarouselSelection() {
        guard !gallery.filteredItems.isEmpty else {
            carouselSelection = nil
            return
        }
        if !gallery.filteredItems.contains(where: { $0.id == carouselSelection }) {
            carouselSelection = gallery.filteredItems[0].id
        }
    }

    private func previousCarouselItem() { moveCarousel(by: -1) }
    private func nextCarouselItem() { moveCarousel(by: 1) }

    private func moveCarousel(by offset: Int) {
        guard let current = carouselSelection,
              let index = gallery.filteredItems.firstIndex(where: { $0.id == current }),
              !gallery.filteredItems.isEmpty else {
            ensureCarouselSelection()
            return
        }
        let next = (index + offset + gallery.filteredItems.count) % gallery.filteredItems.count
        withAnimation(.easeInOut(duration: 0.35)) {
            carouselSelection = gallery.filteredItems[next].id
        }
    }

    private func detailSheet(_ item: MediaItem) -> some View {
        MediaDetailView(
            item: item,
            onReveal: { NSWorkspace.shared.selectFile(item.sourceURL.path, inFileViewerRootedAtPath: "") },
            onDelete: {
                gallery.requestDelete(item)
                if gallery.deletionBlock == nil { _ = gallery.confirmDelete(item) }
            },
            onSetWallpaper: { applyToMainDisplay(item) },
            onChooseDisplay: { beginAssignmentFlow(for: item) }
        )
    }

    /// SwiftUI only presents one sheet from this hierarchy at a time. Dismiss the detail sheet
    /// first, then present the screen picker from its dismissal callback to avoid a delayed picker.
    private func beginAssignmentFlow(for item: MediaItem) {
        pendingAssignmentItem = item
        gallery.selectedItem = nil
    }

    private func presentPendingAssignmentIfNeeded() {
        guard let item = pendingAssignmentItem else { return }
        pendingAssignmentItem = nil
        assignmentItem = item
    }

    private func applyToMainDisplay(_ item: MediaItem) {
        pendingAssignmentItem = nil
        guard let displays else { return }
        guard let target = displays.assignmentTargets.first(where: \.isMain) ?? displays.assignmentTargets.first else {
            displays.reportPageError(wallumeLocalized("未找到可用显示器。"))
            return
        }
        Task {
            await displays.assign(mediaID: item.id, displayIDs: [target.id])
            if displays.pageError == nil { gallery.selectedItem = nil }
        }
    }

    @ViewBuilder
    private func assignmentSheet(_ item: MediaItem) -> some View {
        if let displays {
            DisplaySelectorView(
                mediaName: item.displayName,
                targets: displays.assignmentTargets,
                currentAssignments: Dictionary(uniqueKeysWithValues: displays.cards.compactMap { card in
                    card.media.map { (card.id, $0.displayName) }
                }),
                selectedIDs: Set([preferredAssignmentDisplayID].compactMap { $0 }),
                errorMessage: displays.pageError,
                onCancel: {
                    displays.dismissPageError()
                    assignmentItem = nil
                    onAssignmentFlowFinished()
                },
                onConfirm: { ids in
                    Task {
                        await displays.assign(mediaID: item.id, displayIDs: ids)
                        if displays.pageError == nil {
                            assignmentItem = nil
                            onAssignmentFlowFinished()
                        }
                    }
                }
            )
        }
    }
}

private struct GalleryMediaTile: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipped()
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(item.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(item.pixelWidth) x \(item.pixelHeight)  ·  \(item.codec)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.09))
        }
        .wallumeInteractiveSurface()
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = NSImage(contentsOf: item.thumbnailURL) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Color(nsColor: .underPageBackgroundColor)
        }
    }
}

private struct ProjectionFilmstripTile: View {
    let item: MediaItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                if let image = NSImage(contentsOf: item.thumbnailURL) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else { WallumeDesign.inset }
                Text(item.kind == .image ? wallumeLocalized("静图") : item.durationSeconds.formatted())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(8)
            }
            .frame(width: 230)
            .aspectRatio(1.6, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? WallumeDesign.accent : .white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            }
            .shadow(color: isSelected ? WallumeDesign.accent.opacity(0.18) : .clear, radius: 0, x: 0, y: 3)

            Text(item.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(width: 230, alignment: .leading)
            Text(item.kind == .image
                ? "\(item.pixelWidth) × \(item.pixelHeight) · \(item.codec)"
                : "\(item.pixelWidth) × \(item.pixelHeight) · \(item.frameRate.formatted()) fps")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 230, alignment: .leading)
        }
        .opacity(isSelected ? 1 : 0.72)
        .animation(WallumeDesign.motion, value: isSelected)
    }
}

private struct GalleryCarouselSlide: View {
    let item: MediaItem
    let displayName: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = NSImage(contentsOf: item.coverURL) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color(nsColor: .underPageBackgroundColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: WallumeDesign.largeCornerRadius, style: .continuous))

            LinearGradient(
                colors: [.clear, .black.opacity(0.16), .black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: WallumeDesign.largeCornerRadius, style: .continuous))

            VStack {
                HStack(spacing: 8) {
                    Circle().fill(WallumeDesign.success).frame(width: 7, height: 7)
                    Text(displayName.map { wallumeLocalized("正在 %@ 放映", $0) } ?? wallumeLocalized("准备放映"))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(.black.opacity(0.48), in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.12)) }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
            .padding(16)

            VStack(alignment: .leading, spacing: 7) {
                Text("NOW PROJECTING")
                    .font(.caption2.weight(.bold))
                    .tracking(1.7)
                    .foregroundStyle(.white.opacity(0.58))
                Text(item.displayName)
                    .font(.system(size: 38, weight: .semibold))
                    .tracking(-1.1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(item.kind == .image
                    ? "\(item.pixelWidth) × \(item.pixelHeight) · \(item.codec)"
                    : "\(item.pixelWidth) × \(item.pixelHeight) · \(item.frameRate.formatted()) fps")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
            }
            .padding(28)
            .padding(.trailing, 210)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: WallumeDesign.largeCornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: WallumeDesign.largeCornerRadius, style: .continuous).strokeBorder(.white.opacity(0.1)) }
    }
}

private struct GalleryRailThumbnail: View {
    let item: MediaItem
    let isSelected: Bool

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: item.thumbnailURL) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 96, height: 54)
        .clipped()
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? WallumeDesign.accent : .white.opacity(0.14), lineWidth: isSelected ? 2 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(isSelected ? 1 : 0.58)
        .scaleEffect(isSelected ? 1 : 0.96)
        .animation(.easeOut(duration: 0.18), value: isSelected)
        .accessibilityLabel(item.displayName)
    }
}

/// Captures trackpad and mouse-wheel navigation only while the pointer is over the carousel.
/// The original event is always returned to AppKit, so ordinary scrolling elsewhere is unchanged.
private struct CarouselWheelObserver: NSViewRepresentable {
    let onPrevious: () -> Void
    let onNext: () -> Void

    func makeNSView(context: Context) -> CarouselWheelObserverView {
        let view = CarouselWheelObserverView()
        view.onPrevious = onPrevious
        view.onNext = onNext
        return view
    }

    func updateNSView(_ nsView: CarouselWheelObserverView, context: Context) {
        nsView.onPrevious = onPrevious
        nsView.onNext = onNext
    }
}

private final class CarouselWheelObserverView: NSView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    private var eventMonitor: Any?
    private var accumulatedDelta: CGFloat = 0
    private var lastAdvance = Date.distantPast

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeEventMonitor()
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
            return event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }

        let horizontal = event.scrollingDeltaX
        let vertical = event.scrollingDeltaY
        let delta = abs(horizontal) > abs(vertical) ? horizontal : vertical
        guard delta != 0 else { return }

        accumulatedDelta += delta
        guard abs(accumulatedDelta) >= 28, Date().timeIntervalSince(lastAdvance) > 0.25 else { return }
        if accumulatedDelta < 0 { onNext?() } else { onPrevious?() }
        accumulatedDelta = 0
        lastAdvance = Date()
    }
}
