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

    public init(gallery: GalleryStore, tasks: ImportTaskStore, displays: DisplayFeatureStore? = nil, preferredAssignmentDisplayID: DisplayID? = nil, onAssignmentFlowFinished: @escaping () -> Void = {}, onImportFiles: @escaping () -> Void, onImportFolder: @escaping () -> Void, onDrop: @escaping ([URL]) -> Void) {
        self.gallery = gallery; self.tasks = tasks; self.displays = displays
        self.preferredAssignmentDisplayID = preferredAssignmentDisplayID
        self.onAssignmentFlowFinished = onAssignmentFlowFinished
        self.onImportFiles = onImportFiles; self.onImportFolder = onImportFolder; self.onDrop = onDrop
    }

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18)]
    public var body: some View {
        VStack(spacing: 0) {
            WallumePageHeader("Wallume", subtitle: "让一段画面留在你的桌面上") {
                HStack {
                    Button("导入视频", systemImage: "plus", action: onImportFiles)
                    Button("导入文件夹", systemImage: "folder.badge.plus", action: onImportFolder)
                }
            }
            if let error = gallery.loadError {
                ContentUnavailableView("无法读取图库", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if gallery.filteredItems.isEmpty {
                ContentUnavailableView("导入第一段动态画面", systemImage: "film.stack", description: Text("支持 MOV 和 MP4；导入后可直接分配到显示器"))
            }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        if let featured = gallery.filteredItems.first {
                            Button { gallery.selectedItem = featured } label: {
                                featuredCanvas(featured)
                            }
                            .buttonStyle(.plain)
                            .wallumeInteractiveSurface()
                        }

                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("你的片段").font(.title2.weight(.semibold))
                                Text("\(gallery.filteredItems.count) 段视频，点击即可预览或分配到显示器。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "rectangle.grid.2x2")
                                .foregroundStyle(.secondary)
                        }

                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(gallery.filteredItems) { item in
                                Button { gallery.selectedItem = item } label: {
                                    WallumeMediaTile(item: item)
                                }
                                .buttonStyle(.plain)
                                .wallumeInteractiveSurface()
                            }
                        }
                    }
                    .frame(maxWidth: WallumeDesign.contentWidth, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                }
            }
        }
        .wallumePageBackground()
        .animation(.easeInOut(duration: 0.18), value: gallery.filteredItems.map(\.id))
        .searchable(text: $gallery.searchText, prompt: "搜索壁纸")
        .dropDestination(for: URL.self) { urls, _ in onDrop(urls); return !urls.isEmpty }
        .safeAreaInset(edge: .bottom) {
            if tasks.snapshot.isActive || tasks.snapshot.summary.total > 0 || !tasks.snapshot.warnings.isEmpty { ImportTaskDrawer(store: tasks) }
        }
        .sheet(item: $gallery.selectedItem) { item in
            MediaDetailView(
                item: item,
                onReveal: { NSWorkspace.shared.selectFile(item.sourceURL.path, inFileViewerRootedAtPath: "") },
                onDelete: {
                    gallery.requestDelete(item)
                    if gallery.deletionBlock == nil { _ = gallery.confirmDelete(item) }
                },
                onSetWallpaper: displays.map { _ in
                    {
                        displays?.dismissPageError()
                        gallery.selectedItem = nil
                        assignmentItem = item
                    }
                }
            )
        }
        .sheet(item: $assignmentItem) { item in
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
        .alert("媒体正在使用中", isPresented: Binding(
            get: { gallery.deletionBlock != nil },
            set: { if !$0 { gallery.dismissDeletionBlock() } }
        )) {
            Button("知道了") { gallery.dismissDeletionBlock() }
        } message: {
            Text("请先在显示器页面更换壁纸：\(gallery.deletionBlock?.displays.map(\.name).joined(separator: "、") ?? "")")
        }
    }

    private func featuredCanvas(_ item: MediaItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = NSImage(contentsOf: item.coverURL) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color(nsColor: .underPageBackgroundColor)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(2.05, contentMode: .fit)
            .clipped()

            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    WallumeStatusBadge("当前推荐", systemImage: "sparkles", tint: .white)
                    Text(item.displayName)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(item.pixelWidth) × \(item.pixelHeight)  ·  \(item.frameRate.formatted()) fps")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .padding(24)
            .background(.ultraThinMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 8, bottomTrailingRadius: 8, topTrailingRadius: 0))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WallumeMediaTile: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = NSImage(contentsOf: item.thumbnailURL) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Color(nsColor: .underPageBackgroundColor)
                    }
                }
                .frame(height: 156)
                .clipped()
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(.black.opacity(0.4), in: Circle())
                    .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(item.displayName).font(.headline).lineLimit(1)
            Text("\(item.pixelWidth) × \(item.pixelHeight)  ·  \(item.codec)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
    }
}
