import Foundation

public struct RecoveryCandidate: Equatable, Sendable {
    public let id: UUID
    public let phase: TransactionPhase
    public let aerialID: String
    public let createdAt: Date

    public init(id: UUID, phase: TransactionPhase, aerialID: String, createdAt: Date) {
        self.id = id
        self.phase = phase
        self.aerialID = aerialID
        self.createdAt = createdAt
    }
}

public struct RecoveryReport: Equatable, Sendable {
    public let restored: [URL]
    public let conflicts: [URL]
    public let retainedBackups: [URL]

    public init(restored: [URL], conflicts: [URL], retainedBackups: [URL]) {
        self.restored = restored
        self.conflicts = conflicts
        self.retainedBackups = retainedBackups
    }
}

public enum RecoveryCoordinatorError: Error, Equatable {
    case transactionNotFound(UUID)
    case unsupportedSchema(Int)
    case invalidJournalFile(URL)
    case invalidManifest(UUID)
    case guardedRecoveryFailed(URL)
    case restoredFileVerificationFailed(URL)
}

public struct RecoveryCoordinator: Sendable {
    private let paths: AerialPaths
    private let files: any FileStore
    private let digester: any Digesting
    private let journals: AtomicJSONStore
    private let patcher: WallpaperIndexPatcher
    private let refresher: any WallpaperRefreshing

    public init(
        paths: AerialPaths,
        files: any FileStore,
        digester: any Digesting,
        journals: AtomicJSONStore,
        patcher: WallpaperIndexPatcher,
        refresher: any WallpaperRefreshing
    ) {
        self.paths = paths
        self.files = files
        self.digester = digester
        self.journals = journals
        self.patcher = patcher
        self.refresher = refresher
    }

    public func inspect() throws -> [RecoveryCandidate] {
        guard files.exists(paths.transactionsDirectory) else { return [] }
        var candidates: [RecoveryCandidate] = []
        for journalURL in try files.contents(paths.transactionsDirectory)
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard journalURL.pathExtension == "json" else { continue }
            let manifest = try readManifest(from: journalURL)
            guard manifest.phase != .restored else { continue }
            candidates.append(
                RecoveryCandidate(
                    id: manifest.id,
                    phase: manifest.phase,
                    aerialID: manifest.aerialID,
                    createdAt: manifest.createdAt
                )
            )
        }
        return candidates.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func restore(id: UUID) throws -> RecoveryReport {
        let journalURL = paths.transactionsDirectory.appending(path: "\(id.uuidString).json")
        guard files.exists(journalURL) else {
            throw RecoveryCoordinatorError.transactionNotFound(id)
        }
        var manifest = try readManifest(from: journalURL)
        if manifest.phase == .restored {
            return RecoveryReport(restored: [], conflicts: [], retainedBackups: [])
        }

        var restored: [URL] = []
        var conflicts: [URL] = []

        switch try restoreFile(manifest.video, fallbackBackup: manifest.recoveryBackup, id: id) {
        case .changed: restored.append(manifest.video.target)
        case .alreadyOriginal: break
        case .conflict: conflicts.append(manifest.video.target)
        }
        switch try restoreFile(manifest.poster, fallbackBackup: nil, id: id) {
        case .changed: restored.append(manifest.poster.target)
        case .alreadyOriginal: break
        case .conflict: conflicts.append(manifest.poster.target)
        }

        let indexResult = try restoreIndex(manifest, id: id)
        if indexResult.changed { restored.append(manifest.indexURL) }
        if indexResult.conflicted { conflicts.append(manifest.indexURL) }

        conflicts = unique(conflicts)
        restored = unique(restored)

        let originalsVerified = try originalStateIsVerified(manifest.video)
            && originalStateIsVerified(manifest.poster)
        if conflicts.isEmpty && originalsVerified {
            try removeBackups(for: manifest)
            manifest.phase = .restored
        } else {
            manifest.phase = .conflicted
        }
        try journals.write(manifest, to: journalURL)
        if !restored.isEmpty { try refresher.refresh() }

        return RecoveryReport(
            restored: restored,
            conflicts: conflicts,
            retainedBackups: retainedBackups(for: manifest)
        )
    }

    private func readManifest(from journalURL: URL) throws -> LockScreenTransactionManifest {
        let manifest: LockScreenTransactionManifest
        do {
            manifest = try journals.read(LockScreenTransactionManifest.self, from: journalURL)
        } catch {
            throw RecoveryCoordinatorError.invalidJournalFile(journalURL)
        }
        guard manifest.schemaVersion == 1 else {
            throw RecoveryCoordinatorError.unsupportedSchema(manifest.schemaVersion)
        }
        guard journalURL.deletingPathExtension().lastPathComponent == manifest.id.uuidString else {
            throw RecoveryCoordinatorError.invalidJournalFile(journalURL)
        }
        guard hasConsistentOriginalState(manifest.video),
              hasConsistentOriginalState(manifest.poster),
              manifest.video.originalHash != nil else {
            throw RecoveryCoordinatorError.invalidManifest(manifest.id)
        }
        return manifest
    }

    private func hasConsistentOriginalState(_ record: FileReplacementRecord) -> Bool {
        (record.originalHash == nil) == (record.originalBackup == nil)
    }

    private enum FileRestoreResult { case changed, alreadyOriginal, conflict }

    private func restoreFile(
        _ record: FileReplacementRecord,
        fallbackBackup: URL?,
        id: UUID
    ) throws -> FileRestoreResult {
        if let originalHash = record.originalHash {
            guard files.exists(record.target) else { return .conflict }
            let observedHash = try digester.sha256(of: record.target)
            if observedHash == originalHash { return .alreadyOriginal }
            guard observedHash == record.installedHash else { return .conflict }
            guard let backup = try verifiedBackup(
                primary: record.originalBackup,
                fallback: fallbackBackup,
                expectedHash: originalHash
            ) else { return .conflict }

            let prepared = sibling(of: record.target, id: id, role: "restore")
            try files.copy(backup, to: prepared)
            guard try digester.sha256(of: prepared) == originalHash else {
                try? files.remove(prepared)
                return .conflict
            }
            try files.exchange(record.target, with: prepared)
            let swappedOutHash: String
            do {
                swappedOutHash = try digester.sha256(of: prepared)
            } catch {
                try revertExchange(
                    target: record.target,
                    prepared: prepared,
                    expectedRestoredHash: record.installedHash
                )
                throw error
            }
            guard swappedOutHash == record.installedHash else {
                try revertExchange(
                    target: record.target,
                    prepared: prepared,
                    expectedRestoredHash: swappedOutHash
                )
                return .conflict
            }
            guard try digester.sha256(of: record.target) == originalHash else {
                throw RecoveryCoordinatorError.restoredFileVerificationFailed(record.target)
            }
            try files.remove(prepared)
            return .changed
        }

        guard files.exists(record.target) else { return .alreadyOriginal }
        let quarantine = sibling(of: record.target, id: id, role: "quarantine")
        try files.installExclusively(quarantine, from: record.target)
        let movedHash: String
        do {
            movedHash = try digester.sha256(of: quarantine)
        } catch {
            try restoreQuarantine(record.target, quarantine: quarantine, expectedHash: nil)
            throw error
        }
        guard movedHash == record.installedHash else {
            try restoreQuarantine(record.target, quarantine: quarantine, expectedHash: movedHash)
            return .conflict
        }
        try files.remove(quarantine)
        return .changed
    }

    private func verifiedBackup(
        primary: URL?,
        fallback: URL?,
        expectedHash: String
    ) throws -> URL? {
        for candidate in unique([primary, fallback].compactMap { $0 }) {
            guard files.exists(candidate) else { continue }
            if try digester.sha256(of: candidate) == expectedHash { return candidate }
        }
        return nil
    }

    private func revertExchange(
        target: URL,
        prepared: URL,
        expectedRestoredHash: String
    ) throws {
        do {
            try files.exchange(target, with: prepared)
            guard try digester.sha256(of: target) == expectedRestoredHash else {
                throw RecoveryCoordinatorError.guardedRecoveryFailed(target)
            }
        } catch {
            throw RecoveryCoordinatorError.guardedRecoveryFailed(target)
        }
    }

    private func restoreQuarantine(
        _ target: URL,
        quarantine: URL,
        expectedHash: String?
    ) throws {
        do {
            try files.installExclusively(target, from: quarantine)
            if let expectedHash {
                guard try digester.sha256(of: target) == expectedHash else {
                    throw RecoveryCoordinatorError.guardedRecoveryFailed(target)
                }
            }
        } catch {
            throw RecoveryCoordinatorError.guardedRecoveryFailed(target)
        }
    }

    private struct IndexRestoreResult { let changed: Bool; let conflicted: Bool }

    private func restoreIndex(
        _ manifest: LockScreenTransactionManifest,
        id: UUID
    ) throws -> IndexRestoreResult {
        guard files.exists(manifest.indexURL) else {
            return IndexRestoreResult(changed: false, conflicted: true)
        }
        let snapshot = try files.read(manifest.indexURL)
        let outcome: RestoreOutcome
        do {
            outcome = try patcher.restore(manifest.indexMutations, in: snapshot)
        } catch WallpaperIndexError.invalidPropertyList {
            return IndexRestoreResult(changed: false, conflicted: true)
        }
        guard !outcome.restoredPaths.isEmpty else {
            return IndexRestoreResult(changed: false, conflicted: !outcome.conflicts.isEmpty)
        }

        let prepared = sibling(of: manifest.indexURL, id: id, role: "restore")
        try files.writeAtomically(outcome.data, to: prepared)
        try files.exchange(manifest.indexURL, with: prepared)
        let swappedOut: Data
        do {
            swappedOut = try files.read(prepared)
        } catch {
            try revertIndexExchange(
                target: manifest.indexURL,
                prepared: prepared,
                expectedRestoredData: snapshot
            )
            throw error
        }
        guard swappedOut == snapshot else {
            try revertIndexExchange(
                target: manifest.indexURL,
                prepared: prepared,
                expectedRestoredData: swappedOut
            )
            return IndexRestoreResult(changed: false, conflicted: true)
        }
        guard try files.read(manifest.indexURL) == outcome.data else {
            throw RecoveryCoordinatorError.restoredFileVerificationFailed(manifest.indexURL)
        }
        try files.remove(prepared)
        return IndexRestoreResult(changed: true, conflicted: !outcome.conflicts.isEmpty)
    }

    private func revertIndexExchange(
        target: URL,
        prepared: URL,
        expectedRestoredData: Data?
    ) throws {
        do {
            try files.exchange(target, with: prepared)
            if let expectedRestoredData {
                guard try files.read(target) == expectedRestoredData else {
                    throw RecoveryCoordinatorError.guardedRecoveryFailed(target)
                }
            }
        } catch {
            throw RecoveryCoordinatorError.guardedRecoveryFailed(target)
        }
    }

    private func originalStateIsVerified(_ record: FileReplacementRecord) throws -> Bool {
        if let originalHash = record.originalHash {
            guard files.exists(record.target) else { return false }
            return try digester.sha256(of: record.target) == originalHash
        }
        return !files.exists(record.target)
    }

    private func removeBackups(for manifest: LockScreenTransactionManifest) throws {
        for backup in allBackups(for: manifest) { try files.remove(backup) }
    }

    private func retainedBackups(for manifest: LockScreenTransactionManifest) -> [URL] {
        allBackups(for: manifest).filter { files.exists($0) }
    }

    private func allBackups(for manifest: LockScreenTransactionManifest) -> [URL] {
        unique([
            manifest.video.originalBackup,
            manifest.poster.originalBackup,
            manifest.primaryBackup,
            manifest.recoveryBackup,
        ].compactMap { $0 })
    }

    private func sibling(of target: URL, id: UUID, role: String) -> URL {
        target.deletingLastPathComponent().appending(
            path: ".\(target.lastPathComponent).wallume.\(id.uuidString).\(role).\(UUID().uuidString)"
        )
    }

    private func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
}
