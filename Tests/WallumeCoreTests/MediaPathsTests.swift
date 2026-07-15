import Foundation
import XCTest
@testable import WallumeCore

final class MediaPathsTests: XCTestCase {
    func testMediaPathsStayUnderWallumeOwnedRoots() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = MediaPaths(
            homeDirectory: root.appending(path: "home"),
            cacheDirectory: root.appending(path: "cache")
        )

        XCTAssertEqual(
            paths.libraryIndex.path,
            root.appending(path: "home/Library/Application Support/Wallume/Library/library.json").path
        )
        XCTAssertEqual(paths.variant(id: UUID()).pathExtension, "mov")
        XCTAssertTrue(paths.importWork(id: UUID()).path.hasPrefix(paths.importWorkRoot.path))
    }

    func testMediaItemRoundTripsWithSchemaTwo() throws {
        let item = MediaItem.fixture()
        let encoded = try JSONEncoder().encode(MediaLibraryDocument(items: [item]))

        XCTAssertEqual(
            try JSONDecoder().decode(MediaLibraryDocument.self, from: encoded).schemaVersion,
            2
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private extension MediaItem {
    static func fixture() -> MediaItem {
        MediaItem(
            id: UUID(),
            sourceHash: String(repeating: "a", count: 64),
            sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
            displayName: "Source",
            sourceByteCount: 1,
            pixelWidth: 1920,
            pixelHeight: 1080,
            frameRate: 30,
            durationSeconds: 1,
            codec: "hvc1",
            variantURL: URL(fileURLWithPath: "/tmp/variant.mov"),
            thumbnailURL: URL(fileURLWithPath: "/tmp/thumbnail.jpg"),
            coverURL: URL(fileURLWithPath: "/tmp/cover.jpg"),
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
