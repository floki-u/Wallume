import AppKit
import SwiftUI

@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate {
    private let rootBuilder: () -> AnyView
    private var window: NSWindow?
    public var hasContent: Bool { window?.contentView != nil }
    public var isVisible: Bool { window?.isVisible == true }

    public init(rootBuilder: @escaping () -> AnyView) { self.rootBuilder = rootBuilder }

    public func show() {
        let window = self.window ?? makeWindow()
        if window.contentView == nil { window.contentView = NSHostingView(rootView: rootBuilder()) }
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func closeAndReleaseContent() {
        window?.orderOut(nil)
        window?.contentView = nil
    }

    public func windowWillClose(_ notification: Notification) { window?.contentView = nil }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Wallume"
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }
}
