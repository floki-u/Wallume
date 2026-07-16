import AppKit

@MainActor
public final class StatusItemController {
    private let item: NSStatusItem
    private let onOpen: () -> Void
    private let onCancelCurrent: () -> Void
    private let onCancelAll: () -> Void

    public init(onOpen: @escaping () -> Void, onCancelCurrent: @escaping () -> Void, onCancelAll: @escaping () -> Void) {
        self.onOpen = onOpen; self.onCancelCurrent = onCancelCurrent; self.onCancelAll = onCancelAll
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: "Wallume")
    }

    public func update(_ snapshot: ImportQueueSnapshot) {
        item.button?.title = snapshot.isActive ? " \(Self.title(for: snapshot))" : ""
        let menu = NSMenu()
        menu.addItem(withTitle: Self.title(for: snapshot), action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(actionItem("打开图库", action: #selector(openGallery)))
        if snapshot.isActive {
            menu.addItem(actionItem("取消当前项", action: #selector(cancelCurrent)))
            menu.addItem(actionItem("取消全部", action: #selector(cancelAll)))
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("退出 Wallume", action: #selector(quit)))
        item.menu = menu
    }

    public nonisolated static func title(for snapshot: ImportQueueSnapshot) -> String {
        let summary = snapshot.summary
        if snapshot.isActive { return "导入 \(summary.processed)/\(summary.total)" }
        if summary.failed > 0 { return "\(summary.failed) 个导入失败" }
        return "Wallume"
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: "")
        value.target = self
        return value
    }
    @objc private func openGallery() { onOpen() }
    @objc private func cancelCurrent() { onCancelCurrent() }
    @objc private func cancelAll() { onCancelAll() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
