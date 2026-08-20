import AppKit
import Foundation

public protocol PowerStateProviding: Sendable {
    var isLowPowerModeEnabled: Bool { get }
}

public protocol ThermalStateProviding: Sendable {
    var thermalState: ProcessInfo.ThermalState { get }
}

public struct ProcessInfoPowerState: PowerStateProviding {
    public init() {}
    public var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}

public struct ProcessInfoThermalState: ThermalStateProviding {
    public init() {}
    public var thermalState: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

@MainActor
public final class RuntimeEnvironmentMonitor {
    public static let sessionLockedNotification = Notification.Name("com.apple.screenIsLocked")
    public static let sessionUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    public static let systemWillSleepNotification = NSWorkspace.willSleepNotification
    public static let systemDidWakeNotification = NSWorkspace.didWakeNotification
    public static let thermalStateDidChangeNotification = ProcessInfo.thermalStateDidChangeNotification

    private let sessionCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let processCenter: NotificationCenter
    private let powerState: any PowerStateProviding
    private let thermalState: any ThermalStateProviding
    private let observesDistributedSession: Bool
    private var notificationTokens = [NSObjectProtocol]()
    private var distributedTokens = [NSObjectProtocol]()
    private var onChange: (@MainActor (RuntimeEnvironment) -> Void)?
    private var screenLocked = false
    private var systemSleeping = false
    private var lowPowerMode = false
    private var lowPowerPauseEnabled = false
    private var thermalPressure = false

    public init(
        sessionCenter: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        processCenter: NotificationCenter = .default,
        powerState: any PowerStateProviding = ProcessInfoPowerState(),
        thermalState: any ThermalStateProviding = ProcessInfoThermalState(),
        observesDistributedSession: Bool = true
    ) {
        self.sessionCenter = sessionCenter
        self.workspaceCenter = workspaceCenter
        self.processCenter = processCenter
        self.powerState = powerState
        self.thermalState = thermalState
        self.observesDistributedSession = observesDistributedSession
    }

    public func start(onChange: @escaping @MainActor (RuntimeEnvironment) -> Void) {
        stop()
        self.onChange = onChange
        lowPowerMode = powerState.isLowPowerModeEnabled
        thermalPressure = Self.hasThermalPressure(thermalState.thermalState)

        observe(sessionCenter, name: Self.sessionLockedNotification) { $0.setLocked(true) }
        observe(sessionCenter, name: Self.sessionUnlockedNotification) { $0.setLocked(false) }
        observe(workspaceCenter, name: Self.systemWillSleepNotification) { $0.setSleeping(true) }
        observe(workspaceCenter, name: Self.systemDidWakeNotification) { $0.setSleeping(false) }
        observe(processCenter, name: .NSProcessInfoPowerStateDidChange) { monitor in
            monitor.setLowPower(monitor.powerState.isLowPowerModeEnabled)
        }
        observe(processCenter, name: Self.thermalStateDidChangeNotification) { monitor in
            monitor.setThermalPressure(Self.hasThermalPressure(monitor.thermalState.thermalState))
        }

        if observesDistributedSession {
            observeDistributed(name: Self.sessionLockedNotification) { $0.setLocked(true) }
            observeDistributed(name: Self.sessionUnlockedNotification) { $0.setLocked(false) }
        }
        emit()
    }

    public func stop() {
        notificationTokens.forEach { token in
            sessionCenter.removeObserver(token)
            workspaceCenter.removeObserver(token)
            processCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
        distributedTokens.forEach(DistributedNotificationCenter.default().removeObserver)
        distributedTokens.removeAll()
        onChange = nil
    }

    public func setLowPowerPauseEnabled(_ enabled: Bool) {
        guard lowPowerPauseEnabled != enabled else { return }
        lowPowerPauseEnabled = enabled
        emit()
    }

    private func observe(
        _ center: NotificationCenter,
        name: Notification.Name,
        action: @escaping @MainActor (RuntimeEnvironmentMonitor) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        notificationTokens.append(token)
    }

    private func observeDistributed(
        name: Notification.Name,
        action: @escaping @MainActor (RuntimeEnvironmentMonitor) -> Void
    ) {
        let token = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        distributedTokens.append(token)
    }

    private func setLocked(_ value: Bool) {
        guard screenLocked != value else { return }
        screenLocked = value
        emit()
    }

    private func setSleeping(_ value: Bool) {
        guard systemSleeping != value else { return }
        systemSleeping = value
        emit()
    }

    private func setLowPower(_ value: Bool) {
        guard lowPowerMode != value else { return }
        lowPowerMode = value
        emit()
    }

    private func setThermalPressure(_ value: Bool) {
        guard thermalPressure != value else { return }
        thermalPressure = value
        emit()
    }

    private static func hasThermalPressure(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .critical
    }

    private func emit() {
        onChange?(RuntimeEnvironment(
            userPaused: false,
            appObscured: false,
            screenLocked: screenLocked,
            lowPowerMode: lowPowerPauseEnabled && lowPowerMode,
            systemSleeping: systemSleeping,
            thermalPressure: thermalPressure
        ))
    }
}
