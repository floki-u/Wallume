import AppKit
import SwiftUI
import WallumeCore

public struct GalleryView: View {
    @Bindable private var gallery: GalleryStore
    private let tasks: ImportTaskStore
    private let displays: DisplayFeatureStore?
    private let onImportFiles: () -> Void
    private let onImportFolder: () -> Void
    private let onDrop: ([URL]) -> Void
    @State private var assignmentItem: MediaItem?

    public init(gallery: GalleryStore, tasks: ImportTaskStore, displays: DisplayFeatureStore? = nil, onImportFiles: @escaping () -> Void, onImportFolder: @escaping () -> Void, onDrop: @escaping ([URL]) -> Void) {
        self.gallery = gallery; self.tasks = tasks; self.displays = displays; self.onImportFiles = onImportFiles; self.onImportFolder = onImportFolder; self.onDrop = onDrop
    }

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 16)]
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("我的壁纸").font(.largeTitle.bold())
                Spacer()
                Button("导入文件", systemImage: "plus", action: onImportFiles)
                Button("导入文件夹", systemImage: "folder.badge.plus", action: onImportFolder)
            }.padding()
            if let error = gallery.loadError { ContentUnavailableView("无法读取图库", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else if gallery.filteredItems.isEmpty { ContentUnavailableView("图库为空", systemImage: "film", description: Text("导入 MOV 或 MP4 视频开始使用")) }
            else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(gallery.filteredItems) { item in
                            Button { gallery.selectedItem = item } label: {
                                VStack(alignment: .leading) {
                                    if let image = NSImage(contentsOf: item.thumbnailURL) { Image(nsImage: image).resizable().scaledToFill().frame(height: 110).clipped() }
                                    Text(item.displayName).font(.headline).lineLimit(1)
                                    Text("\(item.pixelWidth)×\(item.pixelHeight) · \(item.codec)").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }.padding()
                }
            }
        }
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
                    { gallery.selectedItem = nil; assignmentItem = item }
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
                    onCancel: { assignmentItem = nil },
                    onConfirm: { ids in
                        Task {
                            await displays.assign(mediaID: item.id, displayIDs: ids)
                            if displays.pageError == nil { assignmentItem = nil }
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
}
