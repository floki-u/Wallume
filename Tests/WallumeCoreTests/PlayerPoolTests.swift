import Foundation
import XCTest
@testable import WallumeCore

final class PlayerPoolTests: XCTestCase {
    func testSameMediaSharesOneResourceUntilLastLeaseReleases() async throws {
        let factory = RecordingPlayerFactory()
        let pool = PlayerPool(factory: factory)
        let media = MediaItem.fixture()

        let first = try await pool.acquire(media: media)
        let second = try await pool.acquire(media: media)
        await pool.release(mediaID: media.id)

        XCTAssertEqual(first.resourceID, second.resourceID)
        XCTAssertEqual(factory.createdIDs.count, 1)
        XCTAssertTrue(factory.releasedIDs.isEmpty)

        await pool.release(mediaID: media.id)
        XCTAssertEqual(factory.releasedIDs, [first.resourceID])
    }

    func testRepeatedPauseDoesNotRepeatResourceCommands() async throws {
        let factory = RecordingPlayerFactory()
        let pool = PlayerPool(factory: factory)
        _ = try await pool.acquire(media: .fixture())

        await pool.setPaused(true)
        await pool.setPaused(true)
        await pool.setPaused(false)

        XCTAssertEqual(factory.pauseCallCount, 1)
        XCTAssertEqual(factory.playCallCount, 2)
    }
}

private final class RecordingPlayerFactory: PlayerFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var created = [UUID]()
    private var released = [UUID]()
    private var playCalls = 0
    private var pauseCalls = 0

    var createdIDs: [UUID] { lock.withLock { created } }
    var releasedIDs: [UUID] { lock.withLock { released } }
    var playCallCount: Int { lock.withLock { playCalls } }
    var pauseCallCount: Int { lock.withLock { pauseCalls } }

    func makePlayer(for media: MediaItem) async throws -> any PlaybackResource {
        let resource = RecordingPlaybackResource { [weak self] id in
            self?.lock.withLock { self?.released.append(id) }
        } didPlay: { [weak self] in
            self?.lock.withLock { self?.playCalls += 1 }
        } didPause: { [weak self] in
            self?.lock.withLock { self?.pauseCalls += 1 }
        }
        lock.withLock { created.append(resource.resourceID) }
        return resource
    }
}

private final class RecordingPlaybackResource: PlaybackResource, @unchecked Sendable {
    let resourceID = UUID()
    private let didRelease: @Sendable (UUID) -> Void
    private let didPlay: @Sendable () -> Void
    private let didPause: @Sendable () -> Void

    init(
        didRelease: @escaping @Sendable (UUID) -> Void,
        didPlay: @escaping @Sendable () -> Void,
        didPause: @escaping @Sendable () -> Void
    ) {
        self.didRelease = didRelease
        self.didPlay = didPlay
        self.didPause = didPause
    }

    func play() async throws { didPlay() }
    func pause() async throws { didPause() }
    func release() async { didRelease(resourceID) }
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
