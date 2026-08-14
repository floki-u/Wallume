import CryptoKit
import Darwin
import Foundation

/// A journal for the macOS 26 Aerial compatibility path.
///
/// Unlike the legacy transaction this never takes over an Apple Aerial slot: it installs a new
/// UUID-named movie, registers one matching manifest entry, and changes only the Aerial choice
/// in the user's wallpaper index. Every removal is hash- and content-guarded.
public struct TahoeAerialTransactionManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public var phase: TransactionPhase
    public let createdAt: Date
    public let registration: TahoeAerialRegistration
    public let manifestURL: URL
    public let manifestBeforeHash: String
    public let manifestAfterHash: String
    public let indexURL: URL
    public let indexMutations: [TahoeIndexMutation]
    /// Exact former value of the current-host `com.apple.screensaver/moduleDict` preference.
    /// Optional so journals written before this field existed remain resettable.
    public let screenSaverModuleBefore: ScreenSaverModuleSnapshot?
    /// Transactions written before the complete-Idle Tahoe protocol changed only an Aerial
    /// configuration. Keep decoding them so an upgrade never removes the user's reset route.
    public let legacyIndexMutations: [PlistMutation]

    public init(
        id: UUID,
        phase: TransactionPhase,
        createdAt: Date,
        registration: TahoeAerialRegistration,
        manifestURL: URL,
        manifestBeforeHash: String,
        manifestAfterHash: String,
        indexURL: URL,
        indexMutations: [TahoeIndexMutation],
        legacyIndexMutations: [PlistMutation] = [],
        screenSaverModuleBefore: ScreenSaverModuleSnapshot? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.phase = phase
        self.createdAt = createdAt
        self.registration = registration
        self.manifestURL = manifestURL
        self.manifestBeforeHash = manifestBeforeHash
        self.manifestAfterHash = manifestAfterHash
        self.indexURL = indexURL
        self.indexMutations = indexMutations
        self.legacyIndexMutations = legacyIndexMutations
        self.screenSaverModuleBefore = screenSaverModuleBefore
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, phase, createdAt, registration, manifestURL, manifestBeforeHash
        case manifestAfterHash, indexURL, indexMutations, screenSaverModuleBefore
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(UUID.self, forKey: .id)
        phase = try values.decode(TransactionPhase.self, forKey: .phase)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        registration = try values.decode(TahoeAerialRegistration.self, forKey: .registration)
        manifestURL = try values.decode(URL.self, forKey: .manifestURL)
        manifestBeforeHash = try values.decode(String.self, forKey: .manifestBeforeHash)
        manifestAfterHash = try values.decode(String.self, forKey: .manifestAfterHash)
        indexURL = try values.decode(URL.self, forKey: .indexURL)
        screenSaverModuleBefore = try values.decodeIfPresent(ScreenSaverModuleSnapshot.self, forKey: .screenSaverModuleBefore)
        if let modern = try? values.decode([TahoeIndexMutation].self, forKey: .indexMutations) {
            indexMutations = modern
            legacyIndexMutations = []
        } else {
            indexMutations = []
            legacyIndexMutations = try values.decode([PlistMutation].self, forKey: .indexMutations)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(id, forKey: .id)
        try values.encode(phase, forKey: .phase)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(registration, forKey: .registration)
        try values.encode(manifestURL, forKey: .manifestURL)
        try values.encode(manifestBeforeHash, forKey: .manifestBeforeHash)
        try values.encode(manifestAfterHash, forKey: .manifestAfterHash)
        try values.encode(indexURL, forKey: .indexURL)
        try values.encodeIfPresent(screenSaverModuleBefore, forKey: .screenSaverModuleBefore)
        if indexMutations.isEmpty, !legacyIndexMutations.isEmpty {
            try values.encode(legacyIndexMutations, forKey: .indexMutations)
        } else {
            try values.encode(indexMutations, forKey: .indexMutations)
        }
    }
}

public struct TahoeAerialTransactionRequest: Sendable {
    public let id: String
    public let displayName: String
    public let optimizedVideo: URL
    public let thumbnail: URL
    public let targetDisplayID: String

    public init(
        id: String,
        displayName: String,
        optimizedVideo: URL,
        thumbnail: URL,
        targetDisplayID: String
    ) {
        self.id = id
        self.displayName = displayName
        self.optimizedVideo = optimizedVideo
        self.thumbnail = thumbnail
        self.targetDisplayID = targetDisplayID
    }
}

public struct TahoeAerialResetReport: Equatable, Sendable {
    public let restored: [URL]
    public let conflicts: [URL]

    public init(restored: [URL], conflicts: [URL]) {
        self.restored = restored
        self.conflicts = conflicts
    }
}

public struct TahoeAerialRecoveryCandidate: Equatable, Sendable {
    public let id: UUID
    public let phase: TransactionPhase
    public let assetID: String
    public let createdAt: Date

    public init(id: UUID, phase: TransactionPhase, assetID: String, createdAt: Date) {
        self.id = id
        self.phase = phase
        self.assetID = assetID
        self.createdAt = createdAt
    }
}

public enum TahoeAerialTransactionError: Error, Equatable, Sendable {
    case missingInput(URL)
    case duplicateAsset(String)
    case invalidAssetID(String)
    case unsafePath(URL)
    case targetChanged(URL)
    case verificationFailed(URL)
    case transactionNotFound(UUID)
    case invalidJournal(URL)
    case unsupportedSchema(Int)
}

public struct TahoeAerialTransaction: Sendable {
    private let paths: AerialPaths
    private let files: any FileStore
    private let digester: any Digesting
    private let journals: AtomicJSONStore
    private let registrations: TahoeAerialRegistrationStore
    private let planner: TahoeAerialTransactionPlanner
    private let catalog: TahoeAerialCatalog
    private let patcher: TahoeWallpaperIndexPatcher
    private let legacyPatcher: WallpaperIndexPatcher
    private let refresher: any WallpaperRefreshing
    private let screenSaverModule: any ScreenSaverModuleConfiguring
    private let thumbnailRenderer: any TahoeThumbnailRendering
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private let advisoryLock: any AdvisoryLocking
    private var pathSafety: PathSafetyValidator { PathSafetyValidator(files: files) }

    public init(
        paths: AerialPaths,
        files: any FileStore,
        digester: any Digesting,
        journals: AtomicJSONStore,
        registrations: TahoeAerialRegistrationStore,
        planner: TahoeAerialTransactionPlanner = TahoeAerialTransactionPlanner(),
        catalog: TahoeAerialCatalog = TahoeAerialCatalog(),
        patcher: TahoeWallpaperIndexPatcher = TahoeWallpaperIndexPatcher(),
        refresher: any WallpaperRefreshing,
        screenSaverModule: any ScreenSaverModuleConfiguring = NoopScreenSaverModuleConfiguration(),
        thumbnailRenderer: (any TahoeThumbnailRendering)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init,
        advisoryLock: (any AdvisoryLocking)? = nil
    ) {
        self.paths = paths
        self.files = files
        self.digester = digester
        self.journals = journals
        self.registrations = registrations
        self.planner = planner
        self.catalog = catalog
        self.patcher = patcher
        legacyPatcher = WallpaperIndexPatcher()
        self.refresher = refresher
        self.screenSaverModule = screenSaverModule
        self.thumbnailRenderer = thumbnailRenderer ?? CopyingTahoeThumbnailRenderer(files: files)
        self.now = now
        self.makeID = makeID
        self.advisoryLock = advisoryLock ?? FileAdvisoryLock(
            url: paths.applicationSupport.appending(path: ".wallume.lock")
        )
    }

    @discardableResult
    public func install(_ request: TahoeAerialTransactionRequest) throws -> TahoeAerialTransactionManifest {
        try validateAssetID(request.id)
        try requireSafeStaticPaths()
        let token = try advisoryLock.acquire()
        defer { withExtendedLifetime(token) {} }
        try requireSafeStaticPaths()

        let video = paths.videosDirectory.appending(path: "\(request.id).mov")
        let thumbnail = paths.thumbnailsDirectory.appending(path: "\(request.id).png")
        let asset = TahoeAerialAsset(
            id: request.id,
            displayName: request.displayName,
            localVideoURL: video,
            localThumbnailURL: thumbnail
        )
        try requireInput(request.optimizedVideo)
        try requireInput(request.thumbnail)
        try requireSafe(request.optimizedVideo, as: .existingRegularFile)
        try requireSafe(request.thumbnail, as: .existingRegularFile)
        try requireSafe(video, as: .regularFileIfPresent)
        try requireSafe(thumbnail, as: .regularFileIfPresent)
        guard !files.exists(video) else { throw TahoeAerialTransactionError.duplicateAsset(request.id) }
        guard !files.exists(registrations.journalURL(for: request.id)) else {
            throw TahoeAerialTransactionError.duplicateAsset(request.id)
        }

        let originalManifest = try files.read(paths.manifest)
        let originalIndex = try files.read(paths.wallpaperIndex)
        let screenSaverModuleBefore = try screenSaverModule.snapshot()
        let plan = try planner.plan(
            asset: asset,
            manifest: originalManifest,
            wallpaperIndex: originalIndex,
            targetDisplayID: request.targetDisplayID
        )
        let videoHash = try digester.sha256(of: request.optimizedVideo)
        var registration = TahoeAerialRegistration(
            asset: TahoeAerialAssetRecord(asset),
            videoHash: videoHash,
            thumbnailHash: "",
            createdAt: now()
        )
        let transactionID = makeID()
        let journalURL = self.journalURL(for: transactionID)
        try files.createDirectory(paths.tahoeTransactionsDirectory.deletingLastPathComponent())
        try files.createPrivateDirectory(paths.tahoeTransactionsDirectory)
        try requireSafe(journalURL, as: .regularFileIfPresent)
        var manifest = TahoeAerialTransactionManifest(
            id: transactionID,
            phase: .prepared,
            createdAt: now(),
            registration: registration,
            manifestURL: paths.manifest,
            manifestBeforeHash: sha256(originalManifest),
            manifestAfterHash: sha256(plan.registeredManifest),
            indexURL: paths.wallpaperIndex,
            indexMutations: plan.indexMutations,
            screenSaverModuleBefore: screenSaverModuleBefore
        )
        try journals.write(manifest, to: journalURL)

        do {
            var writing = manifest
            writing.phase = .writing
            try journals.write(writing, to: journalURL)

            try files.copyExclusively(request.optimizedVideo, to: video)
            try makeSystemReadable(video)
            try verify(video, expectedHash: videoHash)
            try thumbnailRenderer.renderPNG(from: request.thumbnail, to: thumbnail)
            let thumbnailHash = try digester.sha256(of: thumbnail)
            registration = TahoeAerialRegistration(
                asset: TahoeAerialAssetRecord(asset),
                videoHash: videoHash,
                thumbnailHash: thumbnailHash,
                createdAt: registration.createdAt
            )
            manifest = TahoeAerialTransactionManifest(
                id: manifest.id,
                phase: manifest.phase,
                createdAt: manifest.createdAt,
                registration: registration,
                manifestURL: manifest.manifestURL,
                manifestBeforeHash: manifest.manifestBeforeHash,
                manifestAfterHash: manifest.manifestAfterHash,
                indexURL: manifest.indexURL,
                indexMutations: manifest.indexMutations,
                legacyIndexMutations: manifest.legacyIndexMutations,
                screenSaverModuleBefore: manifest.screenSaverModuleBefore
            )
            writing = manifest
            writing.phase = .writing
            try journals.write(writing, to: journalURL)

            guard try files.read(paths.manifest) == originalManifest else {
                throw TahoeAerialTransactionError.targetChanged(paths.manifest)
            }
            try files.writeAtomically(plan.registeredManifest, to: paths.manifest)
            try verify(paths.manifest, expectedHash: manifest.manifestAfterHash)

            guard try files.read(paths.wallpaperIndex) == originalIndex else {
                throw TahoeAerialTransactionError.targetChanged(paths.wallpaperIndex)
            }
            let installedIndex = try patcher.apply(plan.indexMutations, to: originalIndex)
            try files.writeAtomically(installedIndex, to: paths.wallpaperIndex)
            guard try files.read(paths.wallpaperIndex) == installedIndex else {
                throw TahoeAerialTransactionError.verificationFailed(paths.wallpaperIndex)
            }
            try screenSaverModule.activateWallpaperAerials()
            try refresher.refresh()

            writing.phase = .committed
            try journals.write(writing, to: journalURL)
            try registrations.record(registration)
            return writing
        } catch {
            _ = try? resetLocked(id: transactionID, refresh: false)
            throw error
        }
    }

    /// Removes all changes made by one Wallume Tahoe registration, while preserving any data that
    /// macOS or another app changed after installation. Conflicting files are retained and the
    /// journal remains available for a later retry.
    public func reset(id: UUID) throws -> TahoeAerialResetReport {
        let token = try advisoryLock.acquire()
        defer { withExtendedLifetime(token) {} }
        return try resetLocked(id: id, refresh: true)
    }

    public func recoverAll() throws -> [TahoeAerialResetReport] {
        let token = try advisoryLock.acquire()
        defer { withExtendedLifetime(token) {} }
        return try recoveryCandidatesLocked().map { try resetLocked(id: $0.id, refresh: true) }
    }

    public func inspectRecovery() throws -> [TahoeAerialRecoveryCandidate] {
        let token = try advisoryLock.acquire()
        defer { withExtendedLifetime(token) {} }
        return try recoveryCandidatesLocked()
    }

    private func resetLocked(id: UUID, refresh: Bool) throws -> TahoeAerialResetReport {
        let journalURL = self.journalURL(for: id)
        guard files.exists(journalURL) else { throw TahoeAerialTransactionError.transactionNotFound(id) }
        var transaction = try readManifest(from: journalURL)
        transaction.phase = .restoring
        try journals.write(transaction, to: journalURL)

        var restored: [URL] = []
        var conflicts: [URL] = []
        let registration = transaction.registration
        let video = registration.asset.videoURL
        let thumbnail = registration.asset.thumbnailURL

        do {
            let currentManifest = try files.read(paths.manifest)
            let cleanedManifest = try catalog.remove(registration.asset.asset, from: currentManifest)
            if cleanedManifest != currentManifest {
                try files.writeAtomically(cleanedManifest, to: paths.manifest)
                restored.append(paths.manifest)
            }
        } catch TahoeAerialCatalogError.assetMissing {
            // A previous interrupted reset may already have removed our exact entry.
        } catch {
            conflicts.append(paths.manifest)
        }

        do {
            let currentIndex = try files.read(paths.wallpaperIndex)
            let outcome: RestoreOutcome
            if transaction.indexMutations.isEmpty {
                outcome = try legacyPatcher.restore(transaction.legacyIndexMutations, in: currentIndex)
            } else {
                outcome = try patcher.restore(transaction.indexMutations, in: currentIndex)
            }
            if !outcome.restoredPaths.isEmpty {
                try files.writeAtomically(outcome.data, to: paths.wallpaperIndex)
                restored.append(paths.wallpaperIndex)
            }
            if !outcome.conflicts.isEmpty { conflicts.append(paths.wallpaperIndex) }
        } catch {
            conflicts.append(paths.wallpaperIndex)
        }

        // Do not overwrite a screen saver choice made after Wallume's install.  When the Apple
        // Aerial module is still active, restoring the precisely journaled prior value is safe.
        if let screenSaverModuleBefore = transaction.screenSaverModuleBefore {
            do {
                if try screenSaverModule.isWallpaperAerialsActive() {
                    try screenSaverModule.restore(screenSaverModuleBefore)
                }
            } catch {
                conflicts.append(paths.wallpaperIndex)
            }
        }

        do {
            if files.exists(video) {
                guard try digester.sha256(of: video) == registration.videoHash else {
                    throw TahoeAerialTransactionError.targetChanged(video)
                }
                try files.remove(video)
                restored.append(video)
            }
        } catch {
            conflicts.append(video)
        }

        if let thumbnail, let thumbnailHash = registration.thumbnailHash {
            do {
                if files.exists(thumbnail) {
                    guard try digester.sha256(of: thumbnail) == thumbnailHash else {
                        throw TahoeAerialTransactionError.targetChanged(thumbnail)
                    }
                    try files.remove(thumbnail)
                    restored.append(thumbnail)
                }
            } catch {
                conflicts.append(thumbnail)
            }
        }

        restored = unique(restored)
        conflicts = unique(conflicts)
        if conflicts.isEmpty {
            if files.exists(registrations.journalURL(for: registration.asset.id)) {
                try registrations.remove(assetID: registration.asset.id)
            }
            try files.remove(journalURL)
            if refresh, !restored.isEmpty { try refresher.refresh() }
        } else {
            transaction.phase = .conflicted
            try journals.write(transaction, to: journalURL)
        }
        return TahoeAerialResetReport(restored: restored, conflicts: conflicts)
    }

    private func recoveryCandidatesLocked() throws -> [TahoeAerialRecoveryCandidate] {
        guard files.exists(paths.tahoeTransactionsDirectory) else { return [] }
        try requireSafe(paths.tahoeTransactionsDirectory, as: .existingDirectory)
        return try files.contents(paths.tahoeTransactionsDirectory)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try readManifest(from: $0) }
            .map {
                TahoeAerialRecoveryCandidate(
                    id: $0.id,
                    phase: $0.phase,
                    assetID: $0.registration.asset.id,
                    createdAt: $0.createdAt
                )
            }
    }

    private func readManifest(from url: URL) throws -> TahoeAerialTransactionManifest {
        guard try pathSafety.accepts(url, as: .existingRegularFile) else {
            throw TahoeAerialTransactionError.invalidJournal(url)
        }
        let transaction: TahoeAerialTransactionManifest
        do {
            transaction = try journals.read(TahoeAerialTransactionManifest.self, from: url)
        } catch {
            throw TahoeAerialTransactionError.invalidJournal(url)
        }
        guard transaction.schemaVersion == TahoeAerialTransactionManifest.currentSchemaVersion else {
            throw TahoeAerialTransactionError.unsupportedSchema(transaction.schemaVersion)
        }
        guard url.standardizedFileURL.path == journalURL(for: transaction.id).standardizedFileURL.path,
              transaction.manifestURL.standardizedFileURL == paths.manifest.standardizedFileURL,
              transaction.indexURL.standardizedFileURL == paths.wallpaperIndex.standardizedFileURL,
              transaction.registration.asset.videoURL.standardizedFileURL == paths.videosDirectory
                .appending(path: "\(transaction.registration.asset.id).mov").standardizedFileURL else {
            throw TahoeAerialTransactionError.invalidJournal(url)
        }
        try validateAssetID(transaction.registration.asset.id)
        return transaction
    }

    private func requireSafeStaticPaths() throws {
        try requireSafe(paths.videosDirectory, as: .existingDirectory)
        try requireSafe(paths.thumbnailsDirectory, as: .existingDirectory)
        try requireSafe(paths.manifest, as: .existingRegularFile)
        try requireSafe(paths.wallpaperIndex, as: .existingRegularFile)
        try requireSafe(paths.applicationSupport, as: .directoryIfPresent)
        try requireSafe(paths.tahoeTransactionsDirectory, as: .directoryIfPresent)
        try requireSafe(paths.tahoeRegistrationsDirectory, as: .directoryIfPresent)
    }

    private func requireInput(_ url: URL) throws {
        guard files.exists(url) else { throw TahoeAerialTransactionError.missingInput(url) }
    }

    private func requireSafe(_ url: URL, as requirement: PathRequirement) throws {
        guard try pathSafety.accepts(url, as: requirement) else {
            throw TahoeAerialTransactionError.unsafePath(url)
        }
    }

    private func validateAssetID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw TahoeAerialTransactionError.invalidAssetID(id) }
    }

    private func verify(_ url: URL, expectedHash: String) throws {
        guard try digester.sha256(of: url) == expectedHash else {
            throw TahoeAerialTransactionError.verificationFailed(url)
        }
    }

    /// Lock-screen Aerial rendering can be reopened by a system-owned process after the
    /// original user-session preview is gone. AtomicFileStore correctly creates files as 0600,
    /// but that makes an installed movie unreadable to that second renderer. Keep the asset
    /// immutable to everyone except its owner while allowing the renderer to read it.
    private func makeSystemReadable(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw TahoeAerialTransactionError.verificationFailed(url) }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              Darwin.fchmod(descriptor, 0o644) == 0 else {
            throw TahoeAerialTransactionError.verificationFailed(url)
        }
    }

    private func journalURL(for id: UUID) -> URL {
        paths.tahoeTransactionsDirectory.appending(path: "\(id.uuidString).json")
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
