import XCTest
@testable import WallumeCore

final class AerialPathsTests: XCTestCase {
    func testDerivesOnlyKnownUserAndCachePaths() {
        let paths = AerialPaths(
            homeDirectory: URL(fileURLWithPath: "/Users/tester"),
            userGeneratedID: "USER-UUID"
        )
        XCTAssertEqual(paths.videosDirectory.path, "/Users/tester/Library/Application Support/com.apple.wallpaper/aerials/videos")
        XCTAssertEqual(paths.manifest.path, "/Users/tester/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json")
        XCTAssertEqual(paths.tahoeRegistrationsDirectory.path, "/Users/tester/Library/Application Support/Wallume/LockScreen/tahoe-registrations")
        XCTAssertEqual(paths.tahoeTransactionsDirectory.path, "/Users/tester/Library/Application Support/Wallume/LockScreen/tahoe-transactions")
        XCTAssertEqual(paths.wallpaperIndex.path, "/Users/tester/Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        XCTAssertEqual(paths.lockScreenPoster.path, "/Library/Caches/Desktop Pictures/USER-UUID/lockscreen.png")
        XCTAssertEqual(paths.applicationSupport.path, "/Users/tester/Library/Application Support/Wallume")
        XCTAssertEqual(paths.transactionsDirectory.path, "/Users/tester/Library/Application Support/Wallume/LockScreen/transactions")
        XCTAssertEqual(paths.systemBackupsDirectory.path, "/Users/tester/Library/Application Support/Wallume/SystemBackups")
    }
}
