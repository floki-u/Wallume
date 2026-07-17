import Foundation

public actor RuntimeCoordinator {
    private let catalog: any MediaCatalog
    private let pool: PlayerPool
    private var sessions = [DisplayID: RuntimeDisplaySession]()

    public init(catalog: any MediaCatalog, pool: PlayerPool) {
        self.catalog = catalog
        self.pool = pool
    }

    public func reconcile(
        displays: Set<DisplayID>,
        assignments: Set<RuntimeAssignment>,
        environment: RuntimeEnvironment
    ) async -> RuntimeSnapshot {
        var failures = [RuntimeFailure]()

        let assignmentsByDisplay = Dictionary(grouping: assignments, by: \.displayID)
        for (displayID, session) in sessions
        where !displays.contains(displayID) || assignmentsByDisplay[displayID] == nil {
            sessions.removeValue(forKey: displayID)
            await pool.release(mediaID: session.mediaID)
        }

        let duplicateDisplays = assignmentsByDisplay
            .filter { $0.value.count > 1 }
            .map(\.key)

        for displayID in duplicateDisplays.sorted() {
            guard let mediaID = assignmentsByDisplay[displayID]?.map(\.mediaID).sorted(by: { $0.uuidString < $1.uuidString }).first else { continue }
            failures.append(.init(displayID: displayID, mediaID: mediaID, message: "Display has multiple media assignments."))
        }

        for assignment in assignments.sorted(by: { $0.displayID < $1.displayID }) where displays.contains(assignment.displayID) && !duplicateDisplays.contains(assignment.displayID) {
            guard sessions[assignment.displayID]?.mediaID != assignment.mediaID else { continue }
            do {
                guard let item = try catalog.item(id: assignment.mediaID) else {
                    failures.append(.init(displayID: assignment.displayID, mediaID: assignment.mediaID, message: "Media item is unavailable."))
                    continue
                }
                let lease = try await pool.acquire(media: item)
                let previous = sessions.updateValue(.init(displayID: assignment.displayID, mediaID: assignment.mediaID, resourceID: lease.resourceID), forKey: assignment.displayID)
                if let previous { await pool.release(mediaID: previous.mediaID) }
            } catch {
                failures.append(.init(displayID: assignment.displayID, mediaID: assignment.mediaID, message: String(describing: error)))
            }
        }

        await pool.setPaused(!environment.pauseReasons.isEmpty)
        let poolSnapshot = await pool.snapshot()
        return RuntimeSnapshot(
            sessions: Array(sessions.values),
            resourceReferenceCounts: poolSnapshot.resourceReferenceCounts,
            pauseReasons: environment.pauseReasons,
            failures: failures,
            resourceCreationCount: poolSnapshot.resourceCreationCount
        )
    }

    public func shutdown() async -> RuntimeSnapshot {
        for session in sessions.values {
            await pool.release(mediaID: session.mediaID)
        }
        sessions.removeAll()
        await pool.setPaused(false)
        let poolSnapshot = await pool.snapshot()
        return RuntimeSnapshot(
            sessions: [],
            resourceReferenceCounts: poolSnapshot.resourceReferenceCounts,
            pauseReasons: [],
            failures: [],
            resourceCreationCount: poolSnapshot.resourceCreationCount
        )
    }
}
