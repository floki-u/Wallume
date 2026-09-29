import Foundation
import XCTest
@testable import WallumeAppSupport

final class NativeWallpaperProviderCleanupTests: XCTestCase {
    func testCleanupRemovesProviderDocumentsAndPreferences() async throws {
        let homeDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: homeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let paths = NativeWallpaperProviderPaths(homeDirectory: homeDirectory)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data("provider data".utf8).write(to: paths.root.appending(path: "artifact.json"))
        try FileManager.default.createDirectory(
            at: paths.preferencesFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("provider preferences".utf8).write(to: paths.preferencesFile)

        let lifecycle = NativeWallpaperProviderLifecycle(paths: paths)
        try await lifecycle.cleanupAfterReset()

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.preferencesFile.path))
    }
}
