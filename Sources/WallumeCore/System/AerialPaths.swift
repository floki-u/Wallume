import Foundation

public struct AerialPaths: Equatable, Sendable {
    public let videosDirectory: URL
    public let thumbnailsDirectory: URL
    public let manifest: URL
    public let wallpaperIndex: URL
    public let lockScreenPoster: URL
    public let applicationSupport: URL
    public let transactionsDirectory: URL
    public let tahoeRegistrationsDirectory: URL
    public let tahoeTransactionsDirectory: URL
    public let systemBackupsDirectory: URL

    public init(homeDirectory: URL, userGeneratedID: String) {
        let support = homeDirectory.appending(path: "Library/Application Support")
        let wallpaper = support.appending(path: "com.apple.wallpaper")
        let wallume = support.appending(path: WallumeBuildInfo.productName)
        videosDirectory = wallpaper.appending(path: "aerials/videos")
        thumbnailsDirectory = wallpaper.appending(path: "aerials/thumbnails")
        manifest = wallpaper.appending(path: "aerials/manifest/entries.json")
        wallpaperIndex = wallpaper.appending(path: "Store/Index.plist")
        lockScreenPoster = URL(fileURLWithPath: "/Library/Caches/Desktop Pictures")
            .appending(path: userGeneratedID)
            .appending(path: "lockscreen.png")
        applicationSupport = wallume
        transactionsDirectory = wallume.appending(path: "LockScreen/transactions")
        tahoeRegistrationsDirectory = wallume.appending(path: "LockScreen/tahoe-registrations")
        tahoeTransactionsDirectory = wallume.appending(path: "LockScreen/tahoe-transactions")
        systemBackupsDirectory = wallume.appending(path: "SystemBackups")
    }
}
