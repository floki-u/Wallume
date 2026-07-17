import SwiftUI
import WallumeCore

public struct PlaybackToolbarState: Equatable, Sendable {
    public let userPaused: Bool
    public let pauseReasons: Set<RuntimePauseReason>

    public init(userPaused: Bool, pauseReasons: Set<RuntimePauseReason>) {
        self.userPaused = userPaused
        self.pauseReasons = pauseReasons
    }

    public var statusText: String? {
        !pauseReasons.isEmpty && !userPaused ? "已因系统状态暂停" : nil
    }
    public var actionTitle: String { userPaused ? "继续播放" : "暂停播放" }
}

public struct ApplicationShellView: View {
    @Bindable private var navigation: ApplicationNavigation
    private let gallery: GalleryStore
    private let tasks: ImportTaskStore
    private let displays: DisplayFeatureStore?
    private let onImportFiles: () -> Void
    private let onImportFolder: () -> Void
    private let onDrop: ([URL]) -> Void

    public init(gallery: GalleryStore, tasks: ImportTaskStore, displays: DisplayFeatureStore? = nil, navigation: ApplicationNavigation = ApplicationNavigation(), onImportFiles: @escaping () -> Void, onImportFolder: @escaping () -> Void, onDrop: @escaping ([URL]) -> Void) {
        self.gallery = gallery; self.tasks = tasks; self.displays = displays; self.navigation = navigation; self.onImportFiles = onImportFiles; self.onImportFolder = onImportFolder; self.onDrop = onDrop
    }

    public var body: some View {
        NavigationSplitView {
            List(FeatureRegistry.features, selection: $navigation.selection) { feature in
                Label(feature.title, systemImage: feature.systemImage).tag(feature.id)
            }.navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            if navigation.selection == .gallery {
                GalleryView(
                    gallery: gallery,
                    tasks: tasks,
                    displays: displays,
                    preferredAssignmentDisplayID: navigation.preferredAssignmentDisplayID,
                    onAssignmentFlowFinished: { navigation.clearWallpaperTarget() },
                    onImportFiles: onImportFiles,
                    onImportFolder: onImportFolder,
                    onDrop: onDrop
                )
            } else if navigation.selection == .displays, let displays {
                DisplaysView(store: displays) { navigation.openGalleryForWallpaper(displayID: $0) }
            } else {
                ContentUnavailableView("将在后续批次开放", systemImage: FeatureRegistry.features.first { $0.id == navigation.selection }?.systemImage ?? "hammer")
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            if let displays {
                let playback = PlaybackToolbarState(
                    userPaused: displays.userPaused,
                    pauseReasons: displays.effectivePauseReasons
                )
                ToolbarItemGroup {
                    if let status = playback.statusText {
                        Label(status, systemImage: "pause.circle.fill")
                    }
                    Button(playback.actionTitle) {
                        Task { await displays.setUserPaused(!displays.userPaused) }
                    }
                }
            }
        }
    }
}
