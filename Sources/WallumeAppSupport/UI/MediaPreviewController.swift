import AVFoundation
import Foundation
import Observation

@MainActor
public protocol MediaPreviewPlaying: AnyObject {
    var volume: Float { get set }
    func play()
    func pause()
}

extension AVPlayer: MediaPreviewPlaying {}

@MainActor @Observable
public final class MediaPreviewController {
    private let factory: (URL) -> any MediaPreviewPlaying
    private var playback: (any MediaPreviewPlaying)?
    public private(set) var player: AVPlayer?

    public init(factory: @escaping (URL) -> any MediaPreviewPlaying = { AVPlayer(url: $0) }) {
        self.factory = factory
    }

    public func play(_ url: URL) {
        releasePlayer()
        let playback = factory(url)
        playback.volume = 0
        self.playback = playback
        player = playback as? AVPlayer
        playback.play()
    }

    public func releasePlayer() {
        playback?.pause()
        playback = nil
        player = nil
    }
}
