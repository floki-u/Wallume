import AVFoundation
import AppKit
import ScreenSaver

/// Public ScreenSaver entry point. It intentionally owns playback rather than relying on
/// WallpaperAerialsExtension, whose private catalog rejects third-party Aerial entries after a
/// cold restart on Tahoe.
@objc(WallumeScreenSaverView)
public final class WallumeScreenSaverView: ScreenSaverView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var loopObserver: NSObjectProtocol?

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        configureLayer()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        updateAnimationInterval()
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    public override func startAnimation() {
        super.startAnimation()
        loadConfiguredVideo()
    }

    public override func stopAnimation() {
        player.pause()
        super.stopAnimation()
    }

    public override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimationInterval()
    }

    private func updateAnimationInterval() {
        let refreshRate = max(window?.screen?.maximumFramesPerSecond ?? 60, 1)
        animationTimeInterval = 1 / TimeInterval(refreshRate)
    }

    private func loadConfiguredVideo() {
        player.removeAllItems()
        guard let configuration = ScreenSaverConfiguration.load(),
              FileManager.default.isReadableFile(atPath: configuration.videoPath) else {
            playerLayer.player = nil
            return
        }
        player.isMuted = configuration.isMuted
        let item = AVPlayerItem(url: URL(fileURLWithPath: configuration.videoPath))
        player.insert(item, after: nil)
        playerLayer.player = player
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
        player.play()
    }
}

private struct ScreenSaverConfiguration: Decodable {
    let schemaVersion: Int
    let videoPath: String
    let isMuted: Bool

    static func load() -> ScreenSaverConfiguration? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Wallume/ScreenSaver/config.json")
        guard let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(ScreenSaverConfiguration.self, from: data),
              configuration.schemaVersion == 1 else { return nil }
        return configuration
    }
}
