import AppKit
import SwiftUI

@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate {
    private let rootBuilder: () -> AnyView
    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?
    public var hasContent: Bool { hostingController != nil }
    public var isVisible: Bool { window?.isVisible == true }

    public init(rootBuilder: @escaping () -> AnyView) { self.rootBuilder = rootBuilder }

    public func show() {
        let window = self.window ?? makeWindow()
        if window.contentViewController == nil {
            let controller = NSHostingController(rootView: rootBuilder())
            hostingController = controller
            window.contentViewController = controller
            controller.view.frame = window.contentView!.bounds
            controller.view.autoresizingMask = [.width, .height]
        }
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func closeAndReleaseContent() {
        window?.orderOut(nil)
        window?.contentViewController = nil
        hostingController = nil
    }

    public func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        hostingController = nil
    }

    private func makeWindow() -> NSWindow {
        let window = ProjectionWindow(contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Wallume"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }
}

/// The SwiftUI header occupies the full-size content area, while the traffic-light band
/// remains AppKit chrome. Handle double-clicks in that chrome too so both bands match
/// the standard macOS zoom behavior.
private final class ProjectionWindow: NSWindow {
    override func mouseDown(with event: NSEvent) {
        let titlebarBandHeight: CGFloat = 56
        if event.clickCount == 2, event.locationInWindow.y >= frame.height - titlebarBandHeight {
            performZoom(nil)
            return
        }
        super.mouseDown(with: event)
    }
}
