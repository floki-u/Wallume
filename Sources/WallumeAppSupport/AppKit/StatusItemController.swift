import AppKit
import WallumeCore

public struct StatusItemState: Equatable, Sendable {
    public var imports: ImportQueueSnapshot
    public var activeDisplayCount: Int
    public var pauseReasons: Set<RuntimePauseReason>
    public var userPaused: Bool

    public init(
        imports: ImportQueueSnapshot,
        activeDisplayCount: Int,
        pauseReasons: Set<RuntimePauseReason>,
        userPaused: Bool? = nil
    ) {
        self.imports = imports
        self.activeDisplayCount = activeDisplayCount
        self.pauseReasons = pauseReasons
        self.userPaused = userPaused ?? pauseReasons.contains(.user)
    }

    public static let idle = StatusItemState(
        imports: .init(items: [], warnings: [], isActive: false),
        activeDisplayCount: 0,
        pauseReasons: []
    )
}

@MainActor
public final class StatusItemController {
    private let item: NSStatusItem
    private let onOpen: () -> Void
    private let onCancelCurrent: () -> Void
    private let onCancelAll: () -> Void
    private let onOpenDisplays: () -> Void
    private let onSetUserPaused: (Bool) -> Void
    private var state = StatusItemState.idle

    public init(onOpen: @escaping () -> Void, onCancelCurrent: @escaping () -> Void, onCancelAll: @escaping () -> Void, onOpenDisplays: @escaping () -> Void = {}, onSetUserPaused: @escaping (Bool) -> Void = { _ in }) {
        self.onOpen = onOpen; self.onCancelCurrent = onCancelCurrent; self.onCancelAll = onCancelAll
        self.onOpenDisplays = onOpenDisplays; self.onSetUserPaused = onSetUserPaused
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = WallumeStatusImage.make()
        item.button?.imagePosition = .imageOnly
    }

    public func update(_ snapshot: ImportQueueSnapshot) {
        state.imports = snapshot
        render()
    }

    public func updatePlayback(activeDisplayCount: Int, pauseReasons: Set<RuntimePauseReason>, userPaused: Bool) {
        state.activeDisplayCount = activeDisplayCount
        state.pauseReasons = pauseReasons
        state.userPaused = userPaused
        render()
    }

    private func render() {
        let snapshot = state.imports
        item.button?.title = Self.statusBarButtonTitle(for: state)
        let menu = NSMenu()
        menu.addItem(withTitle: Self.title(for: state), action: nil, keyEquivalent: "")
        if let current = snapshot.items.first(where: { $0.attempts.last?.status == .running }), let attempt = current.attempts.last {
            menu.addItem(withTitle: "\(current.source.lastPathComponent) · \(attempt.stage?.rawValue ?? "准备中")", action: nil, keyEquivalent: "")
            if let progress = attempt.progress {
                menu.addItem(withTitle: "进度 \(Int((progress * 100).rounded()))%", action: nil, keyEquivalent: "")
            }
        }
        let summary = snapshot.summary
        if !snapshot.isActive, summary.total > 0 {
            menu.addItem(withTitle: "成功 \(summary.imported) · 重复 \(summary.duplicate) · 失败 \(summary.failed) · 取消 \(summary.cancelled)", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("打开图库", action: #selector(openGallery)))
        menu.addItem(actionItem("打开显示器", action: #selector(openDisplays)))
        if state.activeDisplayCount > 0 {
            if !state.pauseReasons.isEmpty, !state.userPaused {
                menu.addItem(withTitle: "已因系统状态暂停", action: nil, keyEquivalent: "")
            }
            menu.addItem(actionItem(state.userPaused ? "继续播放" : "暂停播放", action: #selector(togglePlayback)))
        }
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

    public nonisolated static func title(for state: StatusItemState) -> String {
        let importTitle = title(for: state.imports)
        if state.imports.isActive || importTitle != "Wallume" { return importTitle }
        guard state.activeDisplayCount > 0 else { return "Wallume" }
        return state.pauseReasons.isEmpty
            ? "播放中 · \(state.activeDisplayCount) 台显示器"
            : "已暂停 · \(state.activeDisplayCount) 台显示器"
    }

    /// The menu bar stays compact; live status is available after opening the icon menu.
    public nonisolated static func statusBarButtonTitle(for state: StatusItemState) -> String { "" }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: "")
        value.target = self
        return value
    }
    @objc private func openGallery() { onOpen() }
    @objc private func openDisplays() { onOpenDisplays() }
    @objc private func togglePlayback() { onSetUserPaused(!state.userPaused) }
    @objc private func cancelCurrent() { onCancelCurrent() }
    @objc private func cancelAll() { onCancelAll() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

private enum WallumeStatusImage {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.black.setStroke()

        let screen = NSBezierPath(roundedRect: NSRect(x: 2, y: 3, width: 14, height: 12), xRadius: 3, yRadius: 3)
        screen.lineWidth = 1.6
        screen.stroke()

        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: 3.6, y: 8.1))
        wave.curve(
            to: NSPoint(x: 14.4, y: 9.2),
            controlPoint1: NSPoint(x: 6.5, y: 11.4),
            controlPoint2: NSPoint(x: 10.8, y: 5.3)
        )
        wave.lineWidth = 1.55
        wave.lineCapStyle = .round
        wave.stroke()

        image.unlockFocus()
        image.isTemplate = true
        image.accessibilityDescription = "Wallume"
        return image
    }
}
