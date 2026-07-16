import AppKit
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

    public init(configuration: Configuration = .desktop) {
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
        window.contentView = NSView(frame: .zero)
        self.window = window
    }

    public func show(frame: CGRect) {
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    public func close() {
        window.close()
    }
}

@MainActor
public final class AppKitDesktopSurfaceFactory: DesktopSurfaceFactory {
    public init() {}

    public func makeSurface(for screen: DesktopScreen) throws -> any DesktopSurface {
        AppKitDesktopSurface()
    }
}
