import AppKit
import Foundation

@MainActor
public final class WindowOcclusionMonitor {
    private let snapshotProvider: any WindowSnapshotProviding
    private let workspaceCenter: NotificationCenter
    private let applicationCenter: NotificationCenter
    private let ownPID: pid_t
    private var displays = [DesktopScreen]()
    private var tokens = [(NotificationCenter, NSObjectProtocol)]()
    private var onChange: (@MainActor (Bool) -> Void)?
    private var lastValue: Bool?

    public init(
        snapshotProvider: any WindowSnapshotProviding = CGWindowSnapshotProvider(),
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        applicationCenter: NotificationCenter = .default,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.snapshotProvider = snapshotProvider; self.workspaceCenter = workspaceCenter
        self.applicationCenter = applicationCenter; self.ownPID = ownPID
    }

    public func start(displays: [DesktopScreen], onChange: @escaping @MainActor (Bool) -> Void) {
        stop(); self.displays = displays; self.onChange = onChange
        observe(workspaceCenter, NSWorkspace.didActivateApplicationNotification)
        observe(workspaceCenter, NSWorkspace.activeSpaceDidChangeNotification)
        observe(applicationCenter, NSApplication.didChangeScreenParametersNotification)
        observe(applicationCenter, NSApplication.didBecomeActiveNotification)
        reevaluate()
    }

    public func updateDisplays(_ displays: [DesktopScreen]) {
        self.displays = displays; reevaluate()
    }

    public func stop() {
        tokens.forEach { $0.0.removeObserver($0.1) }; tokens.removeAll()
        onChange = nil; lastValue = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
        tokens.append((center, token))
    }

    private func reevaluate() {
        let value = snapshotProvider.snapshots().map {
            WindowOcclusionEvaluator().allDisplaysObscured(displays: displays, windows: $0, ownPID: ownPID)
        } ?? false
        guard value != lastValue else { return }
        lastValue = value; onChange?(value)
    }
}
