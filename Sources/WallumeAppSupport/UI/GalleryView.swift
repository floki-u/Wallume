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

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 14)]
    public var body: some View {
        VStack(spacing: 0) {
            WallumePageHeader("图库", subtitle: "选择视频并分配给你的显示器") {
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
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(gallery.filteredItems) { item in
                            Button { gallery.selectedItem = item } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    if let image = NSImage(contentsOf: item.thumbnailURL) {
                                        Image(nsImage: image).resizable().scaledToFill().frame(height: 142).clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                    HStack(spacing: 8) {
                                        Text(item.displayName).font(.headline).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Image(systemName: "play.fill").font(.caption).foregroundStyle(WallumeDesign.accent)
                                    }
                                    Text("\(item.pixelWidth) × \(item.pixelHeight)  ·  \(item.codec)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .wallumeCard()
                            }.buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: WallumeDesign.contentWidth, alignment: .leading)
                    .padding(24)
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
}
