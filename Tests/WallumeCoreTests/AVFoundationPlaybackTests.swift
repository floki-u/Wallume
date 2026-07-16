import AVFoundation
import Foundation
import XCTest
@testable import WallumeCore

final class AVFoundationPlaybackTests: XCTestCase {
    @MainActor
    func testFactoryCreatesMutedResourceRegisteredByID() async throws {
        let registry = AVPlayerPresentationRegistry()
        let factory = AVFoundationPlayerFactory(registry: registry) { _ in }
        let media = MediaItem.playbackFixture()

        let resource = try await factory.makePlayer(for: media)

        XCTAssertTrue(registry.contains(resourceID: resource.resourceID))
        XCTAssertEqual(registry.player(resourceID: resource.resourceID)?.isMuted, true)
        await resource.release()
    }

    @MainActor
    func testFinalPoolReleaseUnregistersSharedPlayer() async throws {
        let registry = AVPlayerPresentationRegistry()
        let factory = AVFoundationPlayerFactory(registry: registry) { _ in }
        let media = MediaItem.playbackFixture()
        let pool = PlayerPool(factory: factory)

        let first = try await pool.acquire(media: media)
        _ = try await pool.acquire(media: media)
        await pool.release(mediaID: media.id)
        XCTAssertTrue(registry.contains(resourceID: first.resourceID))

        await pool.release(mediaID: media.id)
        XCTAssertFalse(registry.contains(resourceID: first.resourceID))
    }
}

private extension MediaItem {
    static func playbackFixture() -> MediaItem {
        MediaItem(
            id: UUID(),
            sourceHash: String(repeating: "a", count: 64),
            sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
            displayName: "Playback",
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
