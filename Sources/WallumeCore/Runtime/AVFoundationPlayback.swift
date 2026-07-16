import AVFoundation
import Foundation

public enum AVFoundationPlaybackError: Error, Equatable {
    case invalidVariant(URL)
}

@MainActor
public final class AVPlayerPresentationRegistry: PlaybackPresentationRegistry {
    private var players = [UUID: AVPlayer]()

    public init() {}

    public func contains(resourceID: UUID) -> Bool {
        players[resourceID] != nil
    }

    public func player(resourceID: UUID) -> AVPlayer? {
        players[resourceID]
    }

    func register(_ player: AVPlayer, resourceID: UUID) {
        players[resourceID] = player
    }

    func unregister(resourceID: UUID) {
        players.removeValue(forKey: resourceID)
    }
}

public final class AVFoundationPlayerFactory: PlayerFactory, @unchecked Sendable {
    public typealias Validating = @Sendable (URL) async throws -> Void

    private let registry: AVPlayerPresentationRegistry
    private let validate: Validating

    public init(
        registry: AVPlayerPresentationRegistry,
        validate: @escaping Validating = AVFoundationPlayerFactory.validateVariant
    ) {
        self.registry = registry
        self.validate = validate
    }

    public func makePlayer(for media: MediaItem) async throws -> any PlaybackResource {
        try await validate(media.variantURL)
        return await MainActor.run {
            AVPlayerPlaybackResource(url: media.variantURL, registry: registry)
        }
    }

    public static func validateVariant(_ url: URL) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw AVFoundationPlaybackError.invalidVariant(url)
        }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable),
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw AVFoundationPlaybackError.invalidVariant(url)
        }
    }
}

@MainActor
public final class AVPlayerPlaybackResource: PlaybackResource {
    public nonisolated let resourceID = UUID()

    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private weak var registry: AVPlayerPresentationRegistry?
    private var isReleased = false

    init(url: URL, registry: AVPlayerPresentationRegistry) {
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .advance
        player.allowsExternalPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        self.player = player
        self.looper = looper
        self.registry = registry
        registry.register(player, resourceID: resourceID)
    }

    public func play() async throws {
        guard !isReleased else { return }
        player.play()
    }

    public func pause() async throws {
        player.pause()
    }

    public func release() async {
        guard !isReleased else { return }
        isReleased = true
        player.pause()
        looper.disableLooping()
        player.removeAllItems()
        registry?.unregister(resourceID: resourceID)
    }
}
