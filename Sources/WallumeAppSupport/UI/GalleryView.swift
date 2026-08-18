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
                ContentUnavailableView("无法读取图库", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if gallery.items.isEmpty {
                VStack(spacing: 20) {
                    ContentUnavailableView(
                        "导入第一段动态画面",
                        systemImage: "film.stack",
                        description: Text("支持 MOV 和 MP4；也可以选择文件夹，Wallume 会递归识别其中的视频。")
                    )
                    HStack(spacing: 12) {
                        Button("导入视频", systemImage: "film") { onImportFiles() }
                            .buttonStyle(.borderedProminent)
                            .tint(WallumeDesign.accent)
                        Button("导入文件夹", systemImage: "folder") { onImportFolder() }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                    projectionLibrary
                    if gallery.filteredItems.isEmpty {
                        ContentUnavailableView("没有匹配的视频", systemImage: "magnifyingglass", description: Text("尝试其他关键词。"))
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
        .alert("媒体正在使用中", isPresented: Binding(
            get: { gallery.deletionBlock != nil },
            set: { if !$0 { gallery.dismissDeletionBlock() } }
        )) {
            Button("知道了") { gallery.dismissDeletionBlock() }
        } message: {
            Text("请先在显示器页面更换壁纸：\(gallery.deletionBlock?.displays.map(\.name).joined(separator: "、") ?? "")")
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 56) { projectionCopy; projectionFeature }.frame(minWidth: 1_180)
            VStack(alignment: .leading, spacing: 24) { projectionCopy; projectionFeature }
        }
        .frame(maxWidth: 2_200)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
    }

    private var projectionCopy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("选一段画面，\n留住此刻的空间。")
                .font(.system(size: 44, weight: .bold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            Text("本地素材不会上传。预览一段画面，再将它投放到指定显示器。")
                .foregroundStyle(.secondary).frame(maxWidth: 350, alignment: .leading)
            Button("预览当前画面", systemImage: "play.fill") { if let item = carouselItem { gallery.selectedItem = item } }
                .buttonStyle(.borderedProminent).tint(WallumeDesign.accent)
        }
        .frame(width: 420, alignment: .leading)
    }

    private var projectionFeature: some View {
        VStack(spacing: 12) {
            ZStack {
                if let item = carouselItem { GalleryCarouselSlide(item: item, displayName: playbackSummary?.displayName) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            HStack(spacing: 8) {
                carouselButton("chevron.left", action: previousCarouselItem)
                Text("画面轮播")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(isAutoCycling ? "暂停轮播" : "自动轮播", systemImage: isAutoCycling ? "pause.fill" : "play.fill") { isAutoCycling.toggle() }
                    .buttonStyle(.bordered)
                carouselButton("chevron.right", action: nextCarouselItem)
                Spacer()
            }
        }
        .frame(minWidth: 700, maxWidth: .infinity)
    }

    private var projectionFilmstrip: some View {
        VStack(spacing: 14) {
            HStack {
                HStack(spacing: 7) {
                    Text("本地画面").font(.caption).foregroundStyle(.secondary)
                    Text(gallery.filteredItems.count.formatted()).font(.caption.weight(.bold)).foregroundStyle(WallumeDesign.accent)
                }
                Spacer()
                Text("全部").font(.caption.weight(.semibold))
                    .padding(.bottom, 5)
                    .overlay(alignment: .bottom) { Rectangle().fill(WallumeDesign.accent).frame(height: 1) }
            }
            .overlay(alignment: .top) { Divider().offset(y: -16) }
            .padding(.horizontal, 32)
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
            .padding(.horizontal, 32)
        }
        .padding(.bottom, 28)
    }

    private var carouselItem: MediaItem? {
        gallery.filteredItems.first { $0.id == carouselSelection } ?? gallery.filteredItems.first
    }

    private func carouselButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.bordered)
        .help(systemImage == "chevron.left" ? "上一段视频" : "下一段视频")
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
            displays.reportPageError("未找到可用显示器。")
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
        ZStack(alignment: .bottomLeading) {
            if let image = NSImage(contentsOf: item.thumbnailURL) {
                Image(nsImage: image).resizable().scaledToFill()
            } else { Color(nsColor: .underPageBackgroundColor) }
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName.uppercased()).font(.caption2.weight(.bold)).lineLimit(1)
                Text(item.durationSeconds.formatted()).font(.caption2)
            }
            .foregroundStyle(.white).padding(10)
        }
        .frame(width: 270)
        .aspectRatio(1.75, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(isSelected ? WallumeDesign.accent : .clear, lineWidth: 2) }
        .opacity(isSelected ? 1 : 0.78)
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
            .clipShape(RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))

            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("正在放映").font(.caption.weight(.semibold))
                    if let displayName {
                        Text(displayName).font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Text(item.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                Text("\(item.pixelWidth) x \(item.pixelHeight)  ·  \(item.frameRate.formatted()) fps")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: WallumeDesign.cardCornerRadius, style: .continuous))
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
