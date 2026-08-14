import Foundation

struct WallpaperHistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let videoURL: URL
    let bookmarkData: Data? // Security-scoped bookmark
    let thumbnailData: Data?
    let dateAdded: Date
    let showAsScreenSaver: Bool
    let showOnAllSpaces: Bool

    init(
        name: String,
        videoURL: URL,
        bookmarkData: Data?,
        thumbnailData: Data?,
        showAsScreenSaver: Bool = false,
        showOnAllSpaces: Bool = false,
    ) {
        self.id = UUID()
        self.name = name
        self.videoURL = videoURL
        self.bookmarkData = bookmarkData
        self.thumbnailData = thumbnailData
        self.dateAdded = Date()
        self.showAsScreenSaver = showAsScreenSaver
        self.showOnAllSpaces = showOnAllSpaces
    }

    static func == (lhs: WallpaperHistoryItem, rhs: WallpaperHistoryItem) -> Bool {
        lhs.id == rhs.id
    }
}
