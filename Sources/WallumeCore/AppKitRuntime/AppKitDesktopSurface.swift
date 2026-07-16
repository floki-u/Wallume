import AppKit
import AVFoundation
import CoreGraphics
import Foundation

@MainActor
public final class AppKitDesktopSurface: DesktopSurface {
    public struct Configuration: Equatable, Sendable {
        public let ignoresMouseEvents: Bool
        public let activates: Bool
        public let joinsAllSpaces: Bool

        public init(
            ignoresMouseEvents: Bool,
            activates: Bool,
            joinsAllSpaces: Bool
        ) {
            self.ignoresMouseEvents = ignoresMouseEvents
            self.activates = activates
            self.joinsAllSpaces = joinsAllSpaces
        }

        public static let desktop = Configuration(
            ignoresMouseEvents: true,
            activates: false,
            joinsAllSpaces: true
        )
    }

    private let window: NSPanel
    private let registry: any PlaybackPresentationRegistry
    private let rootLayer = CALayer()
    private var playerLayer: AVPlayerLayer?
    private var fallbackLayer: CALayer?

    public var videoGravity: AVLayerVideoGravity? { playerLayer?.videoGravity }
    public var presentationLayerIdentity: ObjectIdentifier? {
        playerLayer.map(ObjectIdentifier.init)
    }

    public init(
        registry: any PlaybackPresentationRegistry,
        configuration: Configuration = .desktop
    ) {
        let window = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = configuration.ignoresMouseEvents
        window.hidesOnDeactivate = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = configuration.joinsAllSpaces
            ? [.canJoinAllSpaces, .stationary, .ignoresCycle]
            : [.stationary, .ignoresCycle]
        let contentView = NSView(frame: .zero)
        contentView.wantsLayer = true
        contentView.layer = rootLayer
        window.contentView = contentView
        self.registry = registry
        self.window = window
    }

    public func show(frame: CGRect) {
        window.setFrame(frame, display: true)
        rootLayer.frame = window.contentView?.bounds ?? .zero
        playerLayer?.frame = rootLayer.bounds
        fallbackLayer?.frame = rootLayer.bounds
        window.orderFrontRegardless()
    }

    public func setPresentation(_ presentation: PlaybackPresentation?, fallbackURL: URL?) {
        playerLayer?.removeFromSuperlayer()
        fallbackLayer?.removeFromSuperlayer()
        playerLayer = nil
        fallbackLayer = nil

        if let presentation,
           let player = registry.presentationObject(resourceID: presentation.resourceID) as? AVPlayer {
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = rootLayer.bounds
            rootLayer.addSublayer(layer)
            playerLayer = layer
            return
        }

        guard let fallbackURL, let image = NSImage(contentsOf: fallbackURL) else { return }
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resizeAspectFill
        layer.frame = rootLayer.bounds
        rootLayer.addSublayer(layer)
        fallbackLayer = layer
    }

    public func close() {
        setPresentation(nil, fallbackURL: nil)
        window.close()
    }
}

@MainActor
public final class AppKitDesktopSurfaceFactory: DesktopSurfaceFactory {
    private let registry: any PlaybackPresentationRegistry

    public init(registry: any PlaybackPresentationRegistry) {
        self.registry = registry
    }

    public func makeSurface(for screen: DesktopScreen) throws -> any DesktopSurface {
        AppKitDesktopSurface(registry: registry)
    }
}
