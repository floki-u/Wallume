import Foundation

public protocol PlaybackResource: AnyObject, Sendable {
    var resourceID: UUID { get }
    func play() throws
    func pause() throws
    func release()
}

public protocol PlayerFactory: Sendable {
    func makePlayer(for media: MediaItem) throws -> any PlaybackResource
}

public struct PlayerLease: Equatable, Sendable {
    public let mediaID: UUID
    public let resourceID: UUID

    public init(mediaID: UUID, resourceID: UUID) {
        self.mediaID = mediaID
        self.resourceID = resourceID
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

    public func acquire(media: MediaItem) throws -> PlayerLease {
        if var existing = entries[media.id] {
            existing.referenceCount += 1
            entries[media.id] = existing
            return PlayerLease(mediaID: media.id, resourceID: existing.resource.resourceID)
        }

        let resource = try factory.makePlayer(for: media)
        if !isPaused {
            try resource.play()
        }
        entries[media.id] = Entry(resource: resource, referenceCount: 1)
        resourceCreationCount += 1
        return PlayerLease(mediaID: media.id, resourceID: resource.resourceID)
    }

    public func release(mediaID: UUID) {
        guard var entry = entries[mediaID] else { return }
        entry.referenceCount -= 1
        guard entry.referenceCount == 0 else {
            entries[mediaID] = entry
            return
        }
        entries.removeValue(forKey: mediaID)
        entry.resource.release()
    }

    public func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        for entry in entries.values {
            if paused {
                try? entry.resource.pause()
            } else {
                try? entry.resource.play()
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
