import AppIntents
import AppKit

struct SetWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Video Wallpaper"
    static let description = IntentDescription("Sets a video as your desktop wallpaper")

    @Parameter(title: "Video Name", description: "The name of the video to set as wallpaper")
    var videoName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$videoName) as wallpaper") {
            \.$videoName
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let history = WallpaperHistory.shared

        let wallpaper: WallpaperHistoryItem?
        if let videoName, !videoName.isEmpty {
            wallpaper = history.items.first { $0.name.localizedCaseInsensitiveContains(videoName) }

            if wallpaper == nil {
                let availableNames = history.items.map(\.name).joined(separator: ", ")
                return .result(dialog: "I couldn't find a wallpaper named '\(videoName)'. Available wallpapers: \(availableNames)")
            }
        } else {
            wallpaper = history.items.first

            if wallpaper == nil {
                return .result(dialog: "You don't have any wallpapers saved yet. Please add a video first.")
            }
        }

        guard let wallpaper else {
            return .result(dialog: "Unable to set wallpaper")
        }

        guard let videoURL = history.resolveAndAccessBookmark(for: wallpaper) else {
            return .result(dialog: "Cannot access the video file for '\(wallpaper.name)'. Please make sure the file still exists.")
        }

        await VideoDeploymentService.deployVideo(url: videoURL)
        history.releaseAccess(to: videoURL)

        return .result(dialog: "Set wallpaper to '\(wallpaper.name)'")
    }
}

// MARK: - App Entity

struct WallpaperEntity: AppEntity {
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Video Wallpaper"
    static let defaultQuery = WallpaperQuery()

    init(wallpaper: WallpaperHistoryItem) {
        self.id = wallpaper.id.uuidString
        self.name = wallpaper.name
    }
}

struct WallpaperQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [WallpaperEntity.ID]) async throws -> [WallpaperEntity] {
        WallpaperHistory.shared.items
            .filter { identifiers.contains($0.id.uuidString) }
            .map { WallpaperEntity(wallpaper: $0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [WallpaperEntity] {
        WallpaperHistory.shared.items
            .prefix(5)
            .map { WallpaperEntity(wallpaper: $0) }
    }
}
