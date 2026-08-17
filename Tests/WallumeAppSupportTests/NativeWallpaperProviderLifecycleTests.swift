import Foundation
import Testing
@testable import WallumeAppSupport
import WallumeCore

struct NativeWallpaperProviderLifecycleTests {
    @Test func stagesVideoAndStaticFallback() async throws {
        let fixture = try Fixture()
        let media = try fixture.media(named: "coast")
        let lifecycle = fixture.lifecycle()

        let record = try await lifecycle.prepare(media: media, providerIdentifier: fixture.paths.providerIdentifier)

        #expect(record.mediaID == media.id)
        #expect(record.isActiveInSystem == false)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.videoURL(for: media.id).path))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.fallbackImageURL(for: media.id).path))
    }

    @Test func cleanupRequiresSystemResetBeforeRemovingActiveCache() async throws {
        let fixture = try Fixture()
        let lifecycle = fixture.lifecycle()
        _ = try await lifecycle.prepare(media: try fixture.media(named: "coast"), providerIdentifier: fixture.paths.providerIdentifier)
        try await lifecycle.activateInSystem()

        await #expect(throws: NativeWallpaperProviderLifecycleError.resetRequired) {
            try await lifecycle.cleanupAfterReset()
        }
        try await lifecycle.confirmSystemReset()
        try await lifecycle.cleanupAfterReset()

        #expect(!FileManager.default.fileExists(atPath: fixture.paths.root.path))
    }

    @Test func stagesNewMediaWhileAnOlderProviderAssetRemainsActive() async throws {
        let fixture = try Fixture()
        let lifecycle = fixture.lifecycle()
        let first = try fixture.media(named: "one")
        let second = try fixture.media(named: "two")
        _ = try await lifecycle.prepare(media: first, providerIdentifier: fixture.paths.providerIdentifier)
        try await lifecycle.activateInSystem()

        let replacement = try await lifecycle.prepare(media: second, providerIdentifier: fixture.paths.providerIdentifier)

        #expect(replacement.mediaID == second.id)
        #expect(replacement.isActiveInSystem == false)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.videoURL(for: first.id).path))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.videoURL(for: second.id).path))
    }

    @Test func rejectsMismatchedProviderIdentifier() async throws {
        let fixture = try Fixture()
        let lifecycle = fixture.lifecycle()

        await #expect(throws: NativeWallpaperProviderLifecycleError.invalidProviderIdentifier) {
            try await lifecycle.prepare(media: try fixture.media(named: "coast"), providerIdentifier: "com.example.other")
        }
    }

    @Test func acceptsOnlyMatchingActiveSelectionSignal() async throws {
        let fixture = try Fixture()
        let lifecycle = fixture.lifecycle()
        let media = try fixture.media(named: "coast")
        _ = try await lifecycle.prepare(media: media, providerIdentifier: fixture.paths.providerIdentifier)
        let signal = """
        {"isActive":true,"currentVideoID":"\(media.id.uuidString)"}
        """
        try Data(signal.utf8).write(to: fixture.paths.providerStateFile)

        let record = try await lifecycle.reconcileSystemSelection()

        #expect(record?.isActiveInSystem == true)
        #expect(record?.mediaID == media.id)
    }
}

private final class Fixture {
    let root: URL
    let paths: NativeWallpaperProviderPaths

    init() throws {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/WallumeTests/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = NativeWallpaperProviderPaths(homeDirectory: root)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func lifecycle() -> NativeWallpaperProviderLifecycle {
        NativeWallpaperProviderLifecycle(paths: paths, now: { Date(timeIntervalSince1970: 1) })
    }

    func media(named name: String) throws -> MediaItem {
        let source = root.appending(path: "\(name).mov")
        let cover = root.appending(path: "\(name).jpg")
        try Data("video".utf8).write(to: source)
        try Data("cover".utf8).write(to: cover)
        return MediaItem(
            id: UUID(), sourceHash: name, sourceURL: source, displayName: name,
            sourceByteCount: 5, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30,
            durationSeconds: 1, codec: "hvc1", variantURL: source,
            thumbnailURL: cover, coverURL: cover, createdAt: .distantPast
        )
    }
}
