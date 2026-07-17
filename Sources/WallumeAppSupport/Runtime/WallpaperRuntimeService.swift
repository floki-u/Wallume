import Foundation
import WallumeCore

public protocol RuntimeCoordinating: Sendable {
    func reconcile(
        displays: Set<DisplayID>,
        assignments: Set<RuntimeAssignment>,
        environment: RuntimeEnvironment
    ) async -> RuntimeSnapshot
    func shutdown() async -> RuntimeSnapshot
}

extension RuntimeCoordinator: RuntimeCoordinating {}

@MainActor
public protocol DesktopWindowControlling: AnyObject {
    func reconcile(_ screens: [DesktopScreen]) -> [DesktopSurfaceFailure]
    func apply(
        snapshot: RuntimeSnapshot,
        mediaByID: [UUID: MediaItem],
        modesByDisplay: [DisplayID: WallpaperPresentationMode]
    )
    func closeAll()
}

extension DesktopWindowController: DesktopWindowControlling {}

@MainActor
public protocol RuntimeEnvironmentMonitoring: AnyObject {
    func start(onChange: @escaping @MainActor (RuntimeEnvironment) -> Void)
    func stop()
}

extension RuntimeEnvironmentMonitor: RuntimeEnvironmentMonitoring {}

@MainActor
public protocol RuntimeOcclusionMonitoring: AnyObject {
    func start(displays: [DesktopScreen], onChange: @escaping @MainActor (Bool) -> Void)
    func updateDisplays(_ displays: [DesktopScreen])
    func stop()
}

extension WindowOcclusionMonitor: RuntimeOcclusionMonitoring {}

public struct WallpaperRuntimeSnapshot: Equatable, Sendable {
    public let runtime: RuntimeSnapshot
    public let surfaceFailures: [DesktopSurfaceFailure]
    public var activeDisplayCount: Int { runtime.sessions.count }

    public init(runtime: RuntimeSnapshot, surfaceFailures: [DesktopSurfaceFailure]) {
        self.runtime = runtime
        self.surfaceFailures = surfaceFailures
    }

    public static let empty = WallpaperRuntimeSnapshot(
        runtime: RuntimeSnapshot(
            sessions: [], resourceReferenceCounts: [:], pauseReasons: [],
            failures: [], resourceCreationCount: 0
        ),
        surfaceFailures: []
    )
}

@MainActor
public final class WallpaperRuntimeService {
    private let screens: any DesktopScreenProvider
    private let environmentMonitor: any RuntimeEnvironmentMonitoring
    private let occlusionMonitor: any RuntimeOcclusionMonitoring
    private let runtime: any RuntimeCoordinating
    private let windows: any DesktopWindowControlling
    private let catalog: any MediaCatalog
    private var transientEnvironment = RuntimeEnvironment.active
    private var appObscured = false
    private var reconcileTask: Task<Void, Never>?
    private var reconcileAgain = false
    private var isStarted = false
    private var continuations = [UUID: AsyncStream<WallpaperRuntimeSnapshot>.Continuation]()

    public private(set) var assignments = DisplayAssignmentSnapshot.empty
    public private(set) var latestSnapshot = WallpaperRuntimeSnapshot.empty

    public init(
        screens: any DesktopScreenProvider,
        environmentMonitor: any RuntimeEnvironmentMonitoring,
        occlusionMonitor: any RuntimeOcclusionMonitoring,
        runtime: any RuntimeCoordinating,
        windows: any DesktopWindowControlling,
        catalog: any MediaCatalog
    ) {
        self.screens = screens
        self.environmentMonitor = environmentMonitor
        self.occlusionMonitor = occlusionMonitor
        self.runtime = runtime
        self.windows = windows
        self.catalog = catalog
    }

    public func start(assignments: DisplayAssignmentSnapshot) {
        guard !isStarted else { apply(assignments: assignments); return }
        isStarted = true
        self.assignments = assignments
        screens.start { [weak self] in self?.scheduleReconcile() }
        environmentMonitor.start { [weak self] environment in
            self?.transientEnvironment = environment
            self?.scheduleReconcile()
        }
        occlusionMonitor.start(displays: screens.screens) { [weak self] obscured in
            self?.appObscured = obscured
            self?.scheduleReconcile()
        }
        scheduleReconcile()
    }

    public func apply(assignments: DisplayAssignmentSnapshot) {
        self.assignments = assignments
        scheduleReconcile()
    }

    public func retry() { scheduleReconcile() }

    public func events() -> AsyncStream<WallpaperRuntimeSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(latestSnapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func waitForIdle() async {
        while let task = reconcileTask { await task.value }
    }

    public func stop() async {
        guard isStarted else { return }
        isStarted = false
        screens.stop()
        environmentMonitor.stop()
        occlusionMonitor.stop()
        await waitForIdle()
        windows.closeAll()
        latestSnapshot = WallpaperRuntimeSnapshot(runtime: await runtime.shutdown(), surfaceFailures: [])
        publish()
    }

    private func scheduleReconcile() {
        guard isStarted else { return }
        if reconcileTask != nil { reconcileAgain = true; return }
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                reconcileAgain = false
                await reconcileOnce()
            } while reconcileAgain && isStarted
            reconcileTask = nil
        }
    }

    private func reconcileOnce() async {
        let connectedByID = Dictionary(uniqueKeysWithValues: screens.screens.map { ($0.id, $0) })
        let assignedRecords = assignments.records.filter {
            $0.mediaID != nil && connectedByID[$0.displayID] != nil
        }
        let targetScreens = assignedRecords.compactMap { connectedByID[$0.displayID] }
        occlusionMonitor.updateDisplays(targetScreens)

        let runtimeAssignments = Set(assignedRecords.compactMap { record in
            record.mediaID.map { RuntimeAssignment(displayID: record.displayID, mediaID: $0) }
        })
        var pauseReasons = transientEnvironment.pauseReasons
        if assignments.userPaused { pauseReasons.insert(.user) }
        if appObscured { pauseReasons.insert(.appObscured) }
        let runtimeSnapshot = await runtime.reconcile(
            displays: Set(targetScreens.map(\.id)),
            assignments: runtimeAssignments,
            environment: RuntimeEnvironment(pauseReasons: pauseReasons)
        )

        var mediaByID = [UUID: MediaItem]()
        for mediaID in Set(assignedRecords.compactMap(\.mediaID)) {
            if let item = try? catalog.item(id: mediaID) { mediaByID[mediaID] = item }
        }
        let failures = windows.reconcile(targetScreens)
        windows.apply(
            snapshot: runtimeSnapshot,
            mediaByID: mediaByID,
            modesByDisplay: Dictionary(uniqueKeysWithValues: assignedRecords.map { ($0.displayID, $0.presentationMode) })
        )
        latestSnapshot = WallpaperRuntimeSnapshot(runtime: runtimeSnapshot, surfaceFailures: failures)
        publish()
    }

    private func publish() {
        continuations.values.forEach { $0.yield(latestSnapshot) }
    }
}
