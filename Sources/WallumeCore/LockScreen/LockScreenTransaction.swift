import Foundation

public enum LockScreenTransactionError: Error, Equatable {
    case unsupportedOS(Int)
    case missingInput(URL)
    case backupVerificationFailed(URL)
    case installedFileVerificationFailed(URL)
    case indexVerificationFailed
    case targetChanged(URL)
    case guardedReplacementRecoveryFailed(URL)
    case unsafePath(URL)
}

public struct LockScreenTransaction: Sendable {
    private let paths: AerialPaths
    private let files: any FileStore
    private let digester: any Digesting
    private let journals: AtomicJSONStore
    private let discovery: AerialDiscovery
    private let patcher: WallpaperIndexPatcher
    private let refresher: any WallpaperRefreshing
    private let faults: any FaultInjecting
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private let advisoryLock: any AdvisoryLocking
    private var pathSafety: PathSafetyValidator { PathSafetyValidator(files: files) }

    public init(
        paths: AerialPaths,
        files: any FileStore,
        digester: any Digesting,
        journals: AtomicJSONStore,
        discovery: AerialDiscovery,
        patcher: WallpaperIndexPatcher,
        refresher: any WallpaperRefreshing,
        faults: any FaultInjecting = NoFaults(),
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init,
        advisoryLock: (any AdvisoryLocking)? = nil
    ) {
        self.paths = paths
        self.files = files
        self.digester = digester
        self.journals = journals
        self.discovery = discovery
        self.patcher = patcher
        self.refresher = refresher
        self.faults = faults
        self.now = now
        self.makeID = makeID
        self.advisoryLock = advisoryLock ?? FileAdvisoryLock(
            url: paths.applicationSupport.appending(path: ".wallume.lock")
        )
    }

    public func install(_ request: LockScreenTransactionRequest) throws -> LockScreenTransactionManifest {
        let generation = MacOSGeneration(version: request.systemVersion)
        guard generation.permitsWrites else {
            throw LockScreenTransactionError.unsupportedOS(request.systemVersion.majorVersion)
        }

        try validateStaticPaths(for: request)
        let lockToken = try advisoryLock.acquire()
        defer { withExtendedLifetime(lockToken) {} }

        try validateStaticPaths(for: request)

        let id = makeID()
        let slotVideo = paths.videosDirectory.appending(path: "\(request.aerialID).mov")
        let primaryBackup = slotVideo.deletingLastPathComponent().appending(
            path: slotVideo.lastPathComponent + WallumeBuildInfo.backupMarker
        )
        let recoveryBackup = paths.systemBackupsDirectory
            .appending(path: "\(id.uuidString)-\(slotVideo.lastPathComponent).original")
        let posterBackupPath = paths.systemBackupsDirectory
            .appending(path: "\(id.uuidString)-lockscreen.png.original")
        let journalURL = paths.transactionsDirectory.appending(path: "\(id.uuidString).json")
        for url in [primaryBackup, recoveryBackup, posterBackupPath, journalURL,
                    siblingPreparation(of: slotVideo, id: id),
                    siblingPreparation(of: paths.wallpaperIndex, id: id),
                    siblingPreparation(of: paths.lockScreenPoster, id: id)] {
            try requireSafe(url, as: .regularFileIfPresent)
        }

        _ = try discovery.selectSlot(id: request.aerialID, paths: paths)
        try requireInput(request.optimizedVideo)
        try requireInput(request.poster)
        let originalVideoHash = try digester.sha256(of: slotVideo)
        let installedVideoHash = try digester.sha256(of: request.optimizedVideo)
        let installedPosterHash = try digester.sha256(of: request.poster)
        let originalIndex = try files.read(paths.wallpaperIndex)
        let mutations = try patcher.plan(indexData: originalIndex, aerialID: request.aerialID)

        let posterExists = files.exists(paths.lockScreenPoster)
        let originalPosterHash = posterExists ? try digester.sha256(of: paths.lockScreenPoster) : nil
        let posterBackup = posterExists ? posterBackupPath : nil

        try files.createDirectory(paths.systemBackupsDirectory)
        try files.createDirectory(paths.transactionsDirectory)
        try files.createDirectory(paths.lockScreenPoster.deletingLastPathComponent())
        try verifiedBackup(slotVideo, to: primaryBackup, expectedHash: originalVideoHash)
        try verifiedBackup(slotVideo, to: recoveryBackup, expectedHash: originalVideoHash)
        if let posterBackup, let originalPosterHash {
            try verifiedBackup(paths.lockScreenPoster, to: posterBackup, expectedHash: originalPosterHash)
        }

        var manifest = LockScreenTransactionManifest(
            schemaVersion: 2,
            id: id,
            phase: .prepared,
            createdAt: now(),
            osMajorVersion: request.systemVersion.majorVersion,
            aerialID: request.aerialID,
            video: FileReplacementRecord(
                target: slotVideo,
                originalHash: originalVideoHash,
                installedHash: installedVideoHash,
                originalBackup: primaryBackup
            ),
            poster: FileReplacementRecord(
                target: paths.lockScreenPoster,
                originalHash: originalPosterHash,
                installedHash: installedPosterHash,
                originalBackup: posterBackup
            ),
            indexURL: paths.wallpaperIndex,
            indexMutations: mutations,
            primaryBackup: primaryBackup,
            recoveryBackup: recoveryBackup
        )
        try journals.write(manifest, to: journalURL)
        try faults.hit(.afterPreparedJournal)

        manifest.phase = .writing
        try journals.write(manifest, to: journalURL)

        let preparedVideo = siblingPreparation(of: slotVideo, id: id)
        try files.copy(request.optimizedVideo, to: preparedVideo)
        try guardedExchange(
            slotVideo,
            with: preparedVideo,
            expectedOriginalHash: originalVideoHash
        )
        try verify(slotVideo, expectedHash: installedVideoHash)
        try files.remove(preparedVideo)
        try faults.hit(.afterVideoReplacement)

        let currentIndex = try files.read(paths.wallpaperIndex)
        let installedIndex = try patcher.apply(mutations, to: currentIndex)
        let preparedIndex = siblingPreparation(of: paths.wallpaperIndex, id: id)
        try files.writeAtomically(installedIndex, to: preparedIndex)
        let preExchangeIndex = try files.read(paths.wallpaperIndex)
        guard preExchangeIndex == originalIndex else {
            throw LockScreenTransactionError.targetChanged(paths.wallpaperIndex)
        }
        try guardedExchange(
            paths.wallpaperIndex,
            with: preparedIndex,
            expectedOriginalData: currentIndex
        )
        guard try files.read(paths.wallpaperIndex) == installedIndex else {
            throw LockScreenTransactionError.indexVerificationFailed
        }
        try files.remove(preparedIndex)
        try faults.hit(.afterIndexReplacement)

        let preparedPoster = siblingPreparation(of: paths.lockScreenPoster, id: id)
        try files.copy(request.poster, to: preparedPoster)
        if let originalPosterHash {
            try guardedExchange(
                paths.lockScreenPoster,
                with: preparedPoster,
                expectedOriginalHash: originalPosterHash
            )
        } else {
            do {
                try files.installExclusively(paths.lockScreenPoster, from: preparedPoster)
            } catch let error as POSIXError where error.code == .EEXIST {
                throw LockScreenTransactionError.targetChanged(paths.lockScreenPoster)
            }
        }
        try verify(paths.lockScreenPoster, expectedHash: installedPosterHash)
        try files.remove(preparedPoster)
        try faults.hit(.afterPosterReplacement)

        try refresher.refresh()
        try faults.hit(.beforeCommit)
        manifest.phase = .committed
        try journals.write(manifest, to: journalURL)
        return manifest
    }

    private func requireInput(_ url: URL) throws {
        guard files.exists(url) else { throw LockScreenTransactionError.missingInput(url) }
    }

    private func requireSafe(_ url: URL, as requirement: PathRequirement) throws {
        guard try pathSafety.accepts(url, as: requirement) else {
            throw LockScreenTransactionError.unsafePath(url)
        }
    }

    private func validateStaticPaths(for request: LockScreenTransactionRequest) throws {
        let expectedSlot = paths.videosDirectory.appending(path: "\(request.aerialID).mov")
        let expectedPrimary = expectedSlot.deletingLastPathComponent().appending(
            path: expectedSlot.lastPathComponent + WallumeBuildInfo.backupMarker
        )
        try requireSafe(paths.videosDirectory, as: .existingDirectory)
        try requireSafe(paths.manifest, as: .existingRegularFile)
        try requireSafe(paths.wallpaperIndex, as: .existingRegularFile)
        try requireSafe(paths.lockScreenPoster.deletingLastPathComponent(), as: .existingDirectory)
        try requireSafe(paths.lockScreenPoster, as: .regularFileIfPresent)
        try requireSafe(paths.applicationSupport, as: .directoryIfPresent)
        try requireSafe(paths.transactionsDirectory, as: .directoryIfPresent)
        try requireSafe(paths.systemBackupsDirectory, as: .directoryIfPresent)
        try requireSafe(expectedSlot, as: .existingRegularFile)
        try requireSafe(expectedPrimary, as: .regularFileIfPresent)
        try requireSafe(request.optimizedVideo, as: .existingRegularFile)
        try requireSafe(request.poster, as: .existingRegularFile)
    }

    private func verifiedBackup(_ source: URL, to destination: URL, expectedHash: String) throws {
        do {
            try files.copyExclusively(source, to: destination)
        } catch let error as POSIXError where error.code == .EEXIST {
            // Existing recovery material is never overwritten by a later install.
        }
        guard try digester.sha256(of: destination) == expectedHash else {
            throw LockScreenTransactionError.backupVerificationFailed(destination)
        }
    }

    private func verify(_ target: URL, expectedHash: String) throws {
        guard try digester.sha256(of: target) == expectedHash else {
            throw LockScreenTransactionError.installedFileVerificationFailed(target)
        }
    }

    private func guardedExchange(
        _ target: URL,
        with preparedFile: URL,
        expectedOriginalHash: String
    ) throws {
        try files.exchange(target, with: preparedFile)
        let swappedOutHash: String
        do {
            swappedOutHash = try digester.sha256(of: preparedFile)
        } catch {
            try restoreAfterFailedGuard(target, preparedFile: preparedFile, expectedHash: nil)
            throw error
        }
        guard swappedOutHash == expectedOriginalHash else {
            try restoreAfterFailedGuard(
                target,
                preparedFile: preparedFile,
                expectedHash: swappedOutHash
            )
            throw LockScreenTransactionError.targetChanged(target)
        }
    }

    private func restoreAfterFailedGuard(
        _ target: URL,
        preparedFile: URL,
        expectedHash: String?
    ) throws {
        do {
            try files.exchange(target, with: preparedFile)
            if let expectedHash {
                guard try digester.sha256(of: target) == expectedHash else {
                    throw LockScreenTransactionError.guardedReplacementRecoveryFailed(target)
                }
            }
        } catch {
            throw LockScreenTransactionError.guardedReplacementRecoveryFailed(target)
        }
    }

    private func guardedExchange(
        _ target: URL,
        with preparedFile: URL,
        expectedOriginalData: Data
    ) throws {
        try files.exchange(target, with: preparedFile)
        let swappedOutData: Data
        do {
            swappedOutData = try files.read(preparedFile)
        } catch {
            try restoreDataAfterFailedGuard(target, preparedFile: preparedFile, expectedData: nil)
            throw error
        }
        guard swappedOutData == expectedOriginalData else {
            try restoreDataAfterFailedGuard(
                target,
                preparedFile: preparedFile,
                expectedData: swappedOutData
            )
            throw LockScreenTransactionError.targetChanged(target)
        }
    }

    private func restoreDataAfterFailedGuard(
        _ target: URL,
        preparedFile: URL,
        expectedData: Data?
    ) throws {
        do {
            try files.exchange(target, with: preparedFile)
            if let expectedData {
                guard try files.read(target) == expectedData else {
                    throw LockScreenTransactionError.guardedReplacementRecoveryFailed(target)
                }
            }
        } catch {
            throw LockScreenTransactionError.guardedReplacementRecoveryFailed(target)
        }
    }

    private func siblingPreparation(of target: URL, id: UUID) -> URL {
        target.deletingLastPathComponent()
            .appending(path: ".\(target.lastPathComponent).wallume.\(id.uuidString).prepared")
    }
}
