import Foundation

public enum LockScreenTransactionError: Error, Equatable {
    case unsupportedOS(Int)
    case missingInput(URL)
    case backupVerificationFailed(URL)
    case installedFileVerificationFailed(URL)
    case indexVerificationFailed
    case targetChanged(URL)
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
        makeID: @escaping @Sendable () -> UUID = UUID.init
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
    }

    public func install(_ request: LockScreenTransactionRequest) throws -> LockScreenTransactionManifest {
        let generation = MacOSGeneration(version: request.systemVersion)
        guard generation.permitsWrites else {
            throw LockScreenTransactionError.unsupportedOS(request.systemVersion.majorVersion)
        }

        let slot = try discovery.selectSlot(id: request.aerialID, paths: paths)
        try requireInput(request.optimizedVideo)
        try requireInput(request.poster)
        let originalVideoHash = try digester.sha256(of: slot.videoURL)
        let installedVideoHash = try digester.sha256(of: request.optimizedVideo)
        let installedPosterHash = try digester.sha256(of: request.poster)
        let originalIndex = try files.read(paths.wallpaperIndex)
        let mutations = try patcher.plan(indexData: originalIndex, aerialID: request.aerialID)

        let id = makeID()
        let primaryBackup = slot.videoURL.deletingLastPathComponent().appending(
            path: slot.videoURL.lastPathComponent + WallumeBuildInfo.backupMarker
        )
        let recoveryBackup = paths.systemBackupsDirectory
            .appending(path: "\(id.uuidString)-\(slot.videoURL.lastPathComponent).original")
        let posterExists = files.exists(paths.lockScreenPoster)
        let originalPosterHash = posterExists ? try digester.sha256(of: paths.lockScreenPoster) : nil
        let posterBackup = posterExists
            ? paths.systemBackupsDirectory.appending(path: "\(id.uuidString)-lockscreen.png.original")
            : nil
        let journalURL = paths.transactionsDirectory.appending(path: "\(id.uuidString).json")

        try files.createDirectory(paths.systemBackupsDirectory)
        try files.createDirectory(paths.transactionsDirectory)
        try files.createDirectory(paths.lockScreenPoster.deletingLastPathComponent())
        try verifiedBackup(slot.videoURL, to: primaryBackup, expectedHash: originalVideoHash)
        try verifiedBackup(slot.videoURL, to: recoveryBackup, expectedHash: originalVideoHash)
        if let posterBackup, let originalPosterHash {
            try verifiedBackup(paths.lockScreenPoster, to: posterBackup, expectedHash: originalPosterHash)
        }

        var manifest = LockScreenTransactionManifest(
            schemaVersion: 1,
            id: id,
            phase: .prepared,
            createdAt: now(),
            osMajorVersion: request.systemVersion.majorVersion,
            aerialID: request.aerialID,
            video: FileReplacementRecord(
                target: slot.videoURL,
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

        let preparedVideo = siblingPreparation(of: slot.videoURL, id: id)
        try files.copy(request.optimizedVideo, to: preparedVideo)
        try requireUnchanged(slot.videoURL, expectedHash: originalVideoHash)
        try files.replace(slot.videoURL, with: preparedVideo)
        try verify(slot.videoURL, expectedHash: installedVideoHash)
        try faults.hit(.afterVideoReplacement)

        let currentIndex = try files.read(paths.wallpaperIndex)
        let installedIndex = try patcher.apply(mutations, to: currentIndex)
        let preparedIndex = siblingPreparation(of: paths.wallpaperIndex, id: id)
        try files.writeAtomically(installedIndex, to: preparedIndex)
        let latestIndex = try files.read(paths.wallpaperIndex)
        _ = try patcher.apply(mutations, to: latestIndex)
        guard latestIndex == currentIndex else {
            throw LockScreenTransactionError.targetChanged(paths.wallpaperIndex)
        }
        try files.replace(paths.wallpaperIndex, with: preparedIndex)
        guard try files.read(paths.wallpaperIndex) == installedIndex else {
            throw LockScreenTransactionError.indexVerificationFailed
        }
        try faults.hit(.afterIndexReplacement)

        let preparedPoster = siblingPreparation(of: paths.lockScreenPoster, id: id)
        try files.copy(request.poster, to: preparedPoster)
        try requirePosterUnchanged(originalHash: originalPosterHash)
        try files.replace(paths.lockScreenPoster, with: preparedPoster)
        try verify(paths.lockScreenPoster, expectedHash: installedPosterHash)
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

    private func verifiedBackup(_ source: URL, to destination: URL, expectedHash: String) throws {
        try files.copy(source, to: destination)
        guard try digester.sha256(of: destination) == expectedHash else {
            throw LockScreenTransactionError.backupVerificationFailed(destination)
        }
    }

    private func verify(_ target: URL, expectedHash: String) throws {
        guard try digester.sha256(of: target) == expectedHash else {
            throw LockScreenTransactionError.installedFileVerificationFailed(target)
        }
    }

    private func requireUnchanged(_ target: URL, expectedHash: String) throws {
        guard try digester.sha256(of: target) == expectedHash else {
            throw LockScreenTransactionError.targetChanged(target)
        }
    }

    private func requirePosterUnchanged(originalHash: String?) throws {
        if let originalHash {
            guard files.exists(paths.lockScreenPoster) else {
                throw LockScreenTransactionError.targetChanged(paths.lockScreenPoster)
            }
            try requireUnchanged(paths.lockScreenPoster, expectedHash: originalHash)
        } else if files.exists(paths.lockScreenPoster) {
            throw LockScreenTransactionError.targetChanged(paths.lockScreenPoster)
        }
    }

    private func siblingPreparation(of target: URL, id: UUID) -> URL {
        target.deletingLastPathComponent()
            .appending(path: ".\(target.lastPathComponent).wallume.\(id.uuidString).prepared")
    }
}
