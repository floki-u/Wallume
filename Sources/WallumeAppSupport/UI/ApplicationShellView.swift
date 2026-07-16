import SwiftUI

public struct ApplicationShellView: View {
    @State private var selection: WallumeFeatureID = .gallery
    private let gallery: GalleryStore
    private let tasks: ImportTaskStore
    private let onImportFiles: () -> Void
    private let onImportFolder: () -> Void
    private let onDrop: ([URL]) -> Void

    public init(gallery: GalleryStore, tasks: ImportTaskStore, onImportFiles: @escaping () -> Void, onImportFolder: @escaping () -> Void, onDrop: @escaping ([URL]) -> Void) {
        self.gallery = gallery; self.tasks = tasks; self.onImportFiles = onImportFiles; self.onImportFolder = onImportFolder; self.onDrop = onDrop
    }

    public var body: some View {
        NavigationSplitView {
            List(FeatureRegistry.features, selection: $selection) { feature in
                Label(feature.title, systemImage: feature.systemImage).tag(feature.id)
            }.navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            if selection == .gallery {
                GalleryView(gallery: gallery, tasks: tasks, onImportFiles: onImportFiles, onImportFolder: onImportFolder, onDrop: onDrop)
            } else {
                ContentUnavailableView("将在后续批次开放", systemImage: FeatureRegistry.features.first { $0.id == selection }?.systemImage ?? "hammer")
            }
        }.frame(minWidth: 820, minHeight: 560)
    }
}
