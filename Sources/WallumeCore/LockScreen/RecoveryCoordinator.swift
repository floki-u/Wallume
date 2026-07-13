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
    private static let restoreLock = NSLock()
    private let paths: AerialPaths
    private let files: any FileStore
    private let digester: any Digesting
    private let journals: AtomicJSONStore
    private let patcher: WallpaperIndexPatcher
    private let refresher: any WallpaperRefreshing
    private let advisoryLock: any AdvisoryLocking

    public init(
        paths: AerialPaths,
        files: any FileStore,
        digester: any Digesting,
        journals: AtomicJSONStore,
        patcher: WallpaperIndexPatcher,
        refresher: any WallpaperRefreshing,
        advisoryLock: (any AdvisoryLocking)? = nil
    ) {
        self.paths = paths
        self.files = files
        self.digester = digester
        self.journals = journals
        self.patcher = patcher
        self.refresher = refresher
        self.advisoryLock = advisoryLock ?? FileAdvisoryLock(
            url: paths.applicationSupport.appending(path: ".wallume.lock")
        )
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
        Self.restoreLock.lock()
        defer { Self.restoreLock.unlock() }
        let lockToken = try advisoryLock.acquire()
        defer { withExtendedLifetime(lockToken) {} }
        let journalURL = paths.transactionsDirectory.appending(path: "\(id.uuidString).json")
        guard files.exists(journalURL) else {
            throw RecoveryCoordinatorError.transactionNotFound(id)
        }
        var manifest = try readManifest(from: journalURL)
        if manifest.phase == .restored {
            return RecoveryReport(restored: [], conflicts: [], retainedBackups: [])
        }
        let enteredWhileRestoring = manifest.phase == .restoring

        var restored: [URL] = []
        var conflicts: [URL] = []
        var artifactsToClean: [ArtifactCleanup] = []
        var wroteRestoringJournal = enteredWhileRestoring
        func prepareForMutation() throws {
            guard !wroteRestoringJournal else { return }
            manifest.schemaVersion = 2
            manifest.phase = .restoring
            try journals.write(manifest, to: journalURL)
            wroteRestoringJournal = true
        }

        switch try restoreFile(
            manifest.video,
            fallbackBackup: manifest.recoveryBackup,
            id: id,
            prepareForMutation: prepareForMutation
        ) {
        case let .changed(artifact):
            restored.append(manifest.video.target)
            artifactsToClean.append(artifact)
        case let .alreadyOriginal(artifact):
            if let artifact { artifactsToClean.append(artifact) }
        case .conflict: conflicts.append(manifest.video.target)
        }
        switch try restoreFile(
            manifest.poster,
            fallbackBackup: nil,
            id: id,
            prepareForMutation: prepareForMutation
        ) {
        case let .changed(artifact):
            restored.append(manifest.poster.target)
            artifactsToClean.append(artifact)
        case let .alreadyOriginal(artifact):
            if let artifact { artifactsToClean.append(artifact) }
        case .conflict: conflicts.append(manifest.poster.target)
        }

        let indexResult = try restoreIndex(
            manifest,
            id: id,
            prepareForMutation: prepareForMutation
        )
        if indexResult.changed { restored.append(manifest.indexURL) }
        if indexResult.conflicted { conflicts.append(manifest.indexURL) }
        if let artifact = indexResult.cleanupArtifact { artifactsToClean.append(artifact) }

        conflicts = unique(conflicts)
        restored = unique(restored)

        if enteredWhileRestoring || !restored.isEmpty {
            try refresher.refresh()
        }
        for artifact in uniqueArtifacts(artifactsToClean) {
            if try !cleanup(artifact, id: id) { conflicts.append(artifact.target) }
        }
        conflicts = unique(conflicts)

        let videoOriginalVerified = try originalStateIsVerified(manifest.video)
        let posterOriginalVerified = try originalStateIsVerified(manifest.poster)
        let indexOriginalVerified = try indexOriginalStateIsVerified(manifest)
        if !videoOriginalVerified { conflicts.append(manifest.video.target) }
        if !posterOriginalVerified { conflicts.append(manifest.poster.target) }
        if !indexOriginalVerified { conflicts.append(manifest.indexURL) }
        conflicts.append(contentsOf: try changedBackups(in: manifest))
        conflicts = unique(conflicts)
        let originalsVerified = videoOriginalVerified && posterOriginalVerified && indexOriginalVerified
        if conflicts.isEmpty && originalsVerified {
            if manifest.backupCleanupAuthorized != true {
                manifest.backupCleanupAuthorized = true
                try journals.write(manifest, to: journalURL)
            }
            conflicts.append(contentsOf: try removeBackups(for: manifest, id: id))
        }
        conflicts = unique(conflicts)
        if conflicts.isEmpty && originalsVerified {
            manifest.phase = .restored
        } else {
            manifest.phase = .conflicted
        }
        try journals.write(manifest, to: journalURL)

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
        guard (1...2).contains(manifest.schemaVersion) else {
            throw RecoveryCoordinatorError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.schemaVersion == 2 || manifest.phase != .restoring else {
            throw RecoveryCoordinatorError.invalidManifest(manifest.id)
        }
        guard manifest.schemaVersion == 2 || manifest.backupCleanupAuthorized == nil else {
            throw RecoveryCoordinatorError.invalidManifest(manifest.id)
        }
        guard journalURL.deletingPathExtension().lastPathComponent == manifest.id.uuidString else {
            throw RecoveryCoordinatorError.invalidJournalFile(journalURL)
        }
        guard hasConsistentOriginalState(manifest.video),
              hasConsistentOriginalState(manifest.poster),
              manifest.video.originalHash != nil,
              hasAllowedURLs(manifest) else {
            throw RecoveryCoordinatorError.invalidManifest(manifest.id)
        }
        return manifest
    }

    private func hasAllowedURLs(_ manifest: LockScreenTransactionManifest) -> Bool {
        guard !manifest.aerialID.isEmpty,
              !manifest.aerialID.contains("/"),
              !manifest.aerialID.contains("..") else { return false }
        let video = paths.videosDirectory.appending(path: "\(manifest.aerialID).mov")
        let primary = video.deletingLastPathComponent().appending(
            path: video.lastPathComponent + WallumeBuildInfo.backupMarker
        )
        let recovery = paths.systemBackupsDirectory.appending(
            path: "\(manifest.id.uuidString)-\(video.lastPathComponent).original"
        )
        let posterBackup = paths.systemBackupsDirectory.appending(
            path: "\(manifest.id.uuidString)-lockscreen.png.original"
        )
        guard sameURL(manifest.indexURL, paths.wallpaperIndex),
              sameURL(manifest.video.target, video),
              video.resolvingSymlinksInPath().deletingLastPathComponent()
                == paths.videosDirectory.resolvingSymlinksInPath(),
              sameURL(manifest.poster.target, paths.lockScreenPoster),
              sameURL(manifest.primaryBackup, primary),
              sameURL(manifest.video.originalBackup, primary),
              sameURL(manifest.recoveryBackup, recovery) else { return false }
        if manifest.poster.originalHash == nil {
            return manifest.poster.originalBackup == nil
        }
        return sameURL(manifest.poster.originalBackup, posterBackup)
    }

    private func sameURL(_ first: URL?, _ second: URL) -> Bool {
        guard let first else { return false }
        let firstStandard = first.standardizedFileURL
        let secondStandard = second.standardizedFileURL
        return firstStandard == secondStandard
            && firstStandard.resolvingSymlinksInPath() == secondStandard.resolvingSymlinksInPath()
    }

    private func hasConsistentOriginalState(_ record: FileReplacementRecord) -> Bool {
        (record.originalHash == nil) == (record.originalBackup == nil)
    }

    private enum FileRestoreResult {
        case changed(ArtifactCleanup)
        case alreadyOriginal(ArtifactCleanup?)
        case conflict
    }

    private enum ArtifactExpectation {
        case hash(String)
        case data(Data)
    }

    private struct ArtifactCleanup {
        let url: URL
        let target: URL
        let expectation: ArtifactExpectation
    }

    private func restoreFile(
        _ record: FileReplacementRecord,
        fallbackBackup: URL?,
        id: UUID,
        prepareForMutation: () throws -> Void
    ) throws -> FileRestoreResult {
        if let originalHash = record.originalHash {
            let prepared = sibling(of: record.target, id: id, role: "restore")
            let unexpectedQuarantine = sibling(of: record.target, id: id, role: "quarantine")
            if files.exists(unexpectedQuarantine) { return .conflict }
            guard try reconcileCleanupCapture(for: prepared, id: id) else { return .conflict }
            guard files.exists(record.target) else { return .conflict }
            let observedHash = try digester.sha256(of: record.target)
            if files.exists(prepared) {
                let preparedHash = try digester.sha256(of: prepared)
                switch (observedHash, preparedHash) {
                case (originalHash, record.installedHash):
                    return .changed(
                        artifact(prepared, target: record.target, hash: record.installedHash)
                    )
                case (originalHash, originalHash):
                    return .alreadyOriginal(
                        artifact(prepared, target: record.target, hash: originalHash)
                    )
                case (record.installedHash, originalHash):
                    try prepareForMutation()
                    return try exchangePreparedFile(
                        record,
                        originalHash: originalHash,
                        prepared: prepared
                    )
                default:
                    return .conflict
                }
            }
            if observedHash == originalHash { return .alreadyOriginal(nil) }
            guard observedHash == record.installedHash else { return .conflict }
            guard let backup = try verifiedBackup(
                primary: record.originalBackup,
                fallback: fallbackBackup,
                expectedHash: originalHash
            ) else { return .conflict }

            do {
                try files.copyExclusively(backup, to: prepared)
            } catch let error as POSIXError where error.code == .EEXIST {
                return .conflict
            }
            guard try digester.sha256(of: prepared) == originalHash else {
                return .conflict
            }
            try prepareForMutation()
            return try exchangePreparedFile(
                record,
                originalHash: originalHash,
                prepared: prepared
            )
        }

        let quarantine = sibling(of: record.target, id: id, role: "quarantine")
        let unexpectedPrepared = sibling(of: record.target, id: id, role: "restore")
        if files.exists(unexpectedPrepared) { return .conflict }
        guard try reconcileCleanupCapture(for: quarantine, id: id) else { return .conflict }
        if files.exists(quarantine) {
            guard !files.exists(record.target),
                  try digester.sha256(of: quarantine) == record.installedHash else {
                return .conflict
            }
            return .changed(
                artifact(quarantine, target: record.target, hash: record.installedHash)
            )
        }
        guard files.exists(record.target) else { return .alreadyOriginal(nil) }
        try prepareForMutation()
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
        return .changed(
            artifact(quarantine, target: record.target, hash: record.installedHash)
        )
    }

    private func exchangePreparedFile(
        _ record: FileReplacementRecord,
        originalHash: String,
        prepared: URL
    ) throws -> FileRestoreResult {
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
        let installedTargetHash: String
        do {
            installedTargetHash = try digester.sha256(of: record.target)
        } catch {
            try revertExchange(
                target: record.target,
                prepared: prepared,
                expectedRestoredHash: record.installedHash
            )
            throw error
        }
        guard installedTargetHash == originalHash else {
            try revertExchange(
                target: record.target,
                prepared: prepared,
                expectedRestoredHash: record.installedHash
            )
            return .conflict
        }
        return .changed(
            artifact(prepared, target: record.target, hash: record.installedHash)
        )
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

    private struct IndexRestoreResult {
        let changed: Bool
        let conflicted: Bool
        let cleanupArtifact: ArtifactCleanup?
    }

    private func restoreIndex(
        _ manifest: LockScreenTransactionManifest,
        id: UUID,
        prepareForMutation: () throws -> Void
    ) throws -> IndexRestoreResult {
        guard files.exists(manifest.indexURL) else {
            return IndexRestoreResult(changed: false, conflicted: true, cleanupArtifact: nil)
        }
        let snapshot = try files.read(manifest.indexURL)
        let prepared = sibling(of: manifest.indexURL, id: id, role: "restore")
        let unexpectedQuarantine = sibling(
            of: manifest.indexURL,
            id: id,
            role: "quarantine"
        )
        if files.exists(unexpectedQuarantine) {
            return IndexRestoreResult(changed: false, conflicted: true, cleanupArtifact: nil)
        }
        guard try reconcileCleanupCapture(for: prepared, id: id) else {
            return IndexRestoreResult(changed: false, conflicted: true, cleanupArtifact: nil)
        }
        let outcome: RestoreOutcome
        do {
            outcome = try patcher.restore(manifest.indexMutations, in: snapshot)
        } catch WallpaperIndexError.invalidPropertyList {
            return IndexRestoreResult(changed: false, conflicted: true, cleanupArtifact: nil)
        }
        if files.exists(prepared) {
            let artifactData = try files.read(prepared)
            let artifactOutcome: RestoreOutcome
            do {
                artifactOutcome = try patcher.restore(
                    manifest.indexMutations,
                    in: artifactData
                )
            } catch WallpaperIndexError.invalidPropertyList {
                return IndexRestoreResult(changed: false, conflicted: true, cleanupArtifact: nil)
            }
            if !outcome.restoredPaths.isEmpty,
               try propertyListsAreEqual(outcome.data, artifactData) {
                try prepareForMutation()
                return try exchangePreparedIndex(
                    manifest,
                    snapshot: snapshot,
                    outcome: outcome,
                    prepared: prepared
                )
            }
            if !artifactOutcome.restoredPaths.isEmpty,
               try propertyListsAreEqual(artifactOutcome.data, snapshot) {
                return IndexRestoreResult(
                    changed: true,
                    conflicted: !artifactOutcome.conflicts.isEmpty,
                    cleanupArtifact: artifact(
                        prepared,
                        target: manifest.indexURL,
                        data: artifactData
                    )
                )
            }
            if outcome.restoredPaths.isEmpty,
               outcome.conflicts.isEmpty,
               try propertyListsAreEqual(artifactData, snapshot) {
                return IndexRestoreResult(
                    changed: false,
                    conflicted: !outcome.conflicts.isEmpty,
                    cleanupArtifact: artifact(
                        prepared,
                        target: manifest.indexURL,
                        data: artifactData
                    )
                )
            }
            return IndexRestoreResult(changed: false, conflicted: true, cleanupArtifact: nil)
        }
        guard !outcome.restoredPaths.isEmpty else {
            return IndexRestoreResult(
                changed: false,
                conflicted: !outcome.conflicts.isEmpty,
                cleanupArtifact: nil
            )
        }

        do {
            try files.writeExclusively(outcome.data, to: prepared)
        } catch let error as POSIXError where error.code == .EEXIST {
            return IndexRestoreResult(changed: false, conflicted: true, cleanupArtifact: nil)
        }
        guard try files.read(prepared) == outcome.data else {
            return IndexRestoreResult(changed: false, conflicted: true, cleanupArtifact: nil)
        }
        try prepareForMutation()
        return try exchangePreparedIndex(
            manifest,
            snapshot: snapshot,
            outcome: outcome,
            prepared: prepared
        )
    }

    private func exchangePreparedIndex(
        _ manifest: LockScreenTransactionManifest,
        snapshot: Data,
        outcome: RestoreOutcome,
        prepared: URL
    ) throws -> IndexRestoreResult {
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
            return IndexRestoreResult(changed: false, conflicted: true, cleanupArtifact: nil)
        }
        let installedData: Data
        do {
            installedData = try files.read(manifest.indexURL)
        } catch {
            try revertIndexExchange(
                target: manifest.indexURL,
                prepared: prepared,
                expectedRestoredData: snapshot
            )
            throw error
        }
        guard installedData == outcome.data else {
            try revertIndexExchange(
                target: manifest.indexURL,
                prepared: prepared,
                expectedRestoredData: snapshot
            )
            return IndexRestoreResult(changed: false, conflicted: true, cleanupArtifact: nil)
        }
        return IndexRestoreResult(
            changed: true,
            conflicted: !outcome.conflicts.isEmpty,
            cleanupArtifact: artifact(
                prepared,
                target: manifest.indexURL,
                data: snapshot
            )
        )
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

    private func propertyListsAreEqual(_ first: Data, _ second: Data) throws -> Bool {
        let firstValue = try PropertyListSerialization.propertyList(
            from: first,
            options: [],
            format: nil
        )
        let secondValue = try PropertyListSerialization.propertyList(
            from: second,
            options: [],
            format: nil
        )
        guard let firstObject = firstValue as? NSObject,
              let secondObject = secondValue as? NSObject else {
            return false
        }
        return firstObject.isEqual(secondObject)
    }

    private func artifact(_ url: URL, target: URL, hash: String) -> ArtifactCleanup {
        ArtifactCleanup(url: url, target: target, expectation: .hash(hash))
    }

    private func artifact(_ url: URL, target: URL, data: Data) -> ArtifactCleanup {
        ArtifactCleanup(url: url, target: target, expectation: .data(data))
    }

    private func reconcileCleanupCapture(for artifact: URL, id: UUID) throws -> Bool {
        let capture = cleanupCapture(for: artifact, id: id)
        guard files.exists(capture) else { return true }
        guard !files.exists(artifact) else { return false }
        do {
            try files.installExclusively(artifact, from: capture)
            return true
        } catch let error as POSIXError where error.code == .EEXIST {
            return false
        }
    }

    private func cleanup(_ artifact: ArtifactCleanup, id: UUID) throws -> Bool {
        guard files.exists(artifact.url) else { return false }
        let directory = cleanupDirectory(for: artifact.url, id: id)
        try files.createPrivateDirectory(directory)
        let capture = cleanupCapture(for: artifact.url, id: id)
        guard !files.exists(capture) else { return false }
        do {
            try files.installExclusively(capture, from: artifact.url)
        } catch let error as POSIXError where error.code == .EEXIST {
            return false
        }

        switch artifact.expectation {
        case let .hash(expectedHash):
            let movedHash: String
            do {
                movedHash = try digester.sha256(of: capture)
            } catch {
                try restoreCleanupCapture(artifact.url, capture: capture)
                throw error
            }
            guard movedHash == expectedHash else {
                try restoreCleanupCapture(
                    artifact.url,
                    capture: capture,
                    expectedHash: movedHash
                )
                return false
            }
        case let .data(expectedData):
            let movedData: Data
            do {
                movedData = try files.read(capture)
            } catch {
                try restoreCleanupCapture(artifact.url, capture: capture)
                throw error
            }
            guard movedData == expectedData else {
                try restoreCleanupCapture(
                    artifact.url,
                    capture: capture,
                    expectedData: movedData
                )
                return false
            }
        }
        let identity = try files.identity(of: capture)
        guard try files.removeDurably(capture, ifIdentityMatches: identity) else { return false }
        try removeCleanupDirectoryIfEmpty(directory)
        return true
    }

    private func restoreCleanupCapture(
        _ artifact: URL,
        capture: URL,
        expectedHash: String? = nil,
        expectedData: Data? = nil
    ) throws {
        do {
            try files.installExclusively(artifact, from: capture)
            if let expectedHash {
                guard try digester.sha256(of: artifact) == expectedHash else {
                    throw RecoveryCoordinatorError.guardedRecoveryFailed(artifact)
                }
            }
            if let expectedData {
                guard try files.read(artifact) == expectedData else {
                    throw RecoveryCoordinatorError.guardedRecoveryFailed(artifact)
                }
            }
        } catch {
            throw RecoveryCoordinatorError.guardedRecoveryFailed(artifact)
        }
    }

    private func cleanupDirectory(for artifact: URL, id: UUID) -> URL {
        artifact.deletingLastPathComponent().appending(
            path: ".wallume-cleanup-\(id.uuidString)"
        )
    }

    private func cleanupCapture(for artifact: URL, id: UUID) -> URL {
        cleanupDirectory(for: artifact, id: id).appending(path: artifact.lastPathComponent)
    }

    private func removeCleanupDirectoryIfEmpty(_ directory: URL) throws {
        guard files.exists(directory), try files.contents(directory).isEmpty else { return }
        let identity = try files.identity(of: directory)
        _ = try files.removeDurably(directory, ifIdentityMatches: identity)
    }

    private func originalStateIsVerified(_ record: FileReplacementRecord) throws -> Bool {
        if let originalHash = record.originalHash {
            guard files.exists(record.target) else { return false }
            return try digester.sha256(of: record.target) == originalHash
        }
        return !files.exists(record.target)
    }

    private func indexOriginalStateIsVerified(
        _ manifest: LockScreenTransactionManifest
    ) throws -> Bool {
        guard files.exists(manifest.indexURL) else { return false }
        do {
            let outcome = try patcher.restore(
                manifest.indexMutations,
                in: files.read(manifest.indexURL)
            )
            return outcome.restoredPaths.isEmpty && outcome.conflicts.isEmpty
        } catch {
            return false
        }
    }

    private func removeBackups(
        for manifest: LockScreenTransactionManifest,
        id: UUID
    ) throws -> [URL] {
        var conflicts: [URL] = []
        let videoHash = manifest.video.originalHash!
        for backup in allBackups(for: manifest) {
            if !files.exists(backup), manifest.backupCleanupAuthorized == true { continue }
            let expectedHash = backup == manifest.poster.originalBackup
                ? manifest.poster.originalHash! : videoHash
            let artifact = ArtifactCleanup(
                url: backup,
                target: backup,
                expectation: .hash(expectedHash)
            )
            if try !cleanup(artifact, id: id) { conflicts.append(backup) }
        }
        return conflicts
    }

    private func changedBackups(
        in manifest: LockScreenTransactionManifest
    ) throws -> [URL] {
        var expected: [URL: String] = [:]
        if let videoHash = manifest.video.originalHash {
            for url in [manifest.video.originalBackup, manifest.primaryBackup,
                        manifest.recoveryBackup].compactMap({ $0 }) {
                expected[url] = videoHash
            }
        }
        if let posterHash = manifest.poster.originalHash,
           let posterBackup = manifest.poster.originalBackup {
            expected[posterBackup] = posterHash
        }
        var changed: [URL] = []
        for (url, hash) in expected {
            if !files.exists(url), manifest.backupCleanupAuthorized == true { continue }
            guard files.exists(url), try digester.sha256(of: url) == hash else {
                changed.append(url)
                continue
            }
        }
        return changed
    }

    private func retainedBackups(for manifest: LockScreenTransactionManifest) -> [URL] {
        unique(allBackups(for: manifest).flatMap { backup in
            [backup, cleanupCapture(for: backup, id: manifest.id)].filter(files.exists)
        })
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
            path: ".\(target.lastPathComponent).wallume.\(id.uuidString).\(role)"
        )
    }

    private func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    private func uniqueArtifacts(_ values: [ArtifactCleanup]) -> [ArtifactCleanup] {
        var seen: Set<URL> = []
        return values.filter { seen.insert($0.url).inserted }
    }
}
