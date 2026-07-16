import Foundation

public protocol PlaybackResource: AnyObject, Sendable {
    var resourceID: UUID { get }
    func play() async throws
    func pause() async throws
    func release() async
}

public protocol PlayerFactory: Sendable {
    func makePlayer(for media: MediaItem) async throws -> any PlaybackResource
}

public struct PlaybackPresentation: Equatable, Sendable {
    public let resourceID: UUID
    public init(resourceID: UUID) { self.resourceID = resourceID }
}

public struct PlayerLease: Equatable, Sendable {
    public let mediaID: UUID
    public let resourceID: UUID

    public init(mediaID: UUID, resourceID: UUID) {
        self.mediaID = mediaID
        self.resourceID = resourceID
    }

    public var presentation: PlaybackPresentation {
        PlaybackPresentation(resourceID: resourceID)
    }
}

public struct PlayerPoolSnapshot: Equatable, Sendable {
    public let resourceReferenceCounts: [UUID: Int]
    public let resourceCreationCount: Int

    public init(resourceReferenceCounts: [UUID: Int], resourceCreationCount: Int) {
        self.resourceReferenceCounts = resourceReferenceCounts
        self.resourceCreationCount = resourceCreationCount
    }
}

public actor PlayerPool {
    private struct Entry: Sendable {
        let resource: any PlaybackResource
        var referenceCount: Int
    }

    private let factory: any PlayerFactory
    private var entries = [UUID: Entry]()
    private var isPaused = false
    private var resourceCreationCount = 0

    public init(factory: any PlayerFactory) {
        self.factory = factory
    }

    public func acquire(media: MediaItem) async throws -> PlayerLease {
        if var existing = entries[media.id] {
            existing.referenceCount += 1
            entries[media.id] = existing
            return PlayerLease(mediaID: media.id, resourceID: existing.resource.resourceID)
        }

        let resource = try await factory.makePlayer(for: media)
        if !isPaused {
            try await resource.play()
        }
        entries[media.id] = Entry(resource: resource, referenceCount: 1)
        resourceCreationCount += 1
        return PlayerLease(mediaID: media.id, resourceID: resource.resourceID)
    }

    public func release(mediaID: UUID) async {
        guard var entry = entries[mediaID] else { return }
        entry.referenceCount -= 1
        guard entry.referenceCount == 0 else {
            entries[mediaID] = entry
            return
        }
        entries.removeValue(forKey: mediaID)
        await entry.resource.release()
    }

    public func setPaused(_ paused: Bool) async {
        guard isPaused != paused else { return }
        isPaused = paused
        for entry in entries.values {
            if paused {
                try? await entry.resource.pause()
            } else {
                try? await entry.resource.play()
            }
        }
    }

    public func snapshot() -> PlayerPoolSnapshot {
        PlayerPoolSnapshot(
            resourceReferenceCounts: entries.mapValues(\.referenceCount),
            resourceCreationCount: resourceCreationCount
        )
    }
}
