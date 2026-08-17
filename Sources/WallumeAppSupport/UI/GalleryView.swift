import AppKit
import SwiftUI
import WallumeCore

private enum GalleryLayoutMode: String, CaseIterable, Identifiable {
    case adaptive
    case fourColumns
    case carousel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adaptive: "自适应"
        case .fourColumns: "每行 4 个"
        case .carousel: "轮播"
        }
    }

    var systemImage: String {
        switch self {
        case .adaptive: "rectangle.grid.1x2"
        case .fourColumns: "rectangle.grid.2x2.fill"
        case .carousel: "rectangle.on.rectangle.angled"
        }
    }
}

public struct GalleryView: View {
    @Bindable private var gallery: GalleryStore
    private let tasks: ImportTaskStore
    private let displays: DisplayFeatureStore?
    private let preferredAssignmentDisplayID: DisplayID?
    private let onAssignmentFlowFinished: () -> Void
    private let onImportFiles: () -> Void
    private let onImportFolder: () -> Void
    private let onDrop: ([URL]) -> Void
    @AppStorage("wallume.gallery.layout") private var layoutRawValue = GalleryLayoutMode.adaptive.rawValue
    @State private var assignmentItem: MediaItem?
    @State private var carouselSelection: UUID?

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
                ContentUnavailableView("导入第一段动态画面", systemImage: "film.stack", description: Text("支持 MOV 和 MP4；导入后可直接分配到显示器。"))
            } else {
                VStack(spacing: 0) {
                    galleryHeader
                    Divider()
                    if gallery.filteredItems.isEmpty {
                        ContentUnavailableView("没有匹配的视频", systemImage: "magnifyingglass", description: Text("尝试其他关键词。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if selectedLayout == .carousel {
                        carousel
                    } else {
                        mediaGrid
                    }
                }
            }
        }
        .wallumePageBackground()
        .animation(.easeInOut(duration: 0.2), value: gallery.filteredItems.map(\.id))
        .searchable(text: $gallery.searchText, prompt: "搜索素材")
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return !urls.isEmpty
        }
        .safeAreaInset(edge: .bottom) {
            if tasks.snapshot.isActive || tasks.snapshot.summary.total > 0 || !tasks.snapshot.warnings.isEmpty {
                ImportTaskDrawer(store: tasks)
            }
        }
        .sheet(item: $gallery.selectedItem) { item in detailSheet(item) }
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
        .task(id: layoutRawValue) { await advanceCarouselAutomatically() }
    }

    private var selectedLayout: GalleryLayoutMode {
        GalleryLayoutMode(rawValue: layoutRawValue) ?? .adaptive
    }

    private var galleryHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("素材库").font(.title2.weight(.semibold))
                Text("点击素材以预览视频或应用到显示器。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            layoutMenu
            importControls
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var layoutMenu: some View {
        Menu {
            Section("排列方式") {
                ForEach(GalleryLayoutMode.allCases) { layout in
                    Button {
                        layoutRawValue = layout.rawValue
                    } label: {
                        Label(layout.title, systemImage: selectedLayout == layout ? "checkmark" : layout.systemImage)
                    }
                }
            }
        } label: {
            Label("排列", systemImage: selectedLayout.systemImage)
        }
        .help("选择素材排列方式")
    }

    private var importControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Button("导入视频", systemImage: "plus", action: onImportFiles)
                    .buttonStyle(.borderedProminent)
                importMenu
            }
            HStack(spacing: 4) {
                Button(action: onImportFiles) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
                .help("导入视频")
                importMenu
            }
        }
    }

    private var importMenu: some View {
        Menu {
            Button("导入文件夹", systemImage: "folder.badge.plus", action: onImportFolder)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("更多导入选项")
    }

    private var mediaGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(gallery.filteredItems) { item in
                    Button { gallery.selectedItem = item } label: {
                        GalleryMediaTile(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
    }

    private var gridColumns: [GridItem] {
        switch selectedLayout {
        case .adaptive:
            [GridItem(.adaptive(minimum: 190, maximum: 300), spacing: 16)]
        case .fourColumns:
            Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16), count: 4)
        case .carousel:
            []
        }
    }

    private var carousel: some View {
        GeometryReader { geometry in
            ZStack {
                if let item = carouselItem {
                    Button { gallery.selectedItem = item } label: {
                        GalleryCarouselSlide(item: item)
                    }
                    .buttonStyle(.plain)
                    .frame(
                        width: min(1_600, max(640, geometry.size.width - 140)),
                        height: max(360, geometry.size.height - 48)
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 28)
                            .onEnded { value in
                                if value.translation.width < 0 { nextCarouselItem() }
                                if value.translation.width > 0 { previousCarouselItem() }
                            }
                    )
                }

                HStack {
                    carouselButton("chevron.left", action: previousCarouselItem)
                    Spacer()
                    carouselButton("chevron.right", action: nextCarouselItem)
                }
                .padding(.horizontal, 28)
            }
            .background(
                CarouselWheelObserver(
                    onPrevious: previousCarouselItem,
                    onNext: nextCarouselItem
                )
            )
        }
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

    private func advanceCarouselAutomatically() async {
        guard selectedLayout == .carousel else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, selectedLayout == .carousel else { return }
            nextCarouselItem()
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
            onChooseDisplay: { assignmentItem = item }
        )
    }

    private func applyToMainDisplay(_ item: MediaItem) {
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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

private struct GalleryCarouselSlide: View {
    let item: MediaItem

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
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                Text("\(item.pixelWidth) x \(item.pixelHeight)  ·  \(item.frameRate.formatted()) fps")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 8, bottomTrailingRadius: 8, topTrailingRadius: 0))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
