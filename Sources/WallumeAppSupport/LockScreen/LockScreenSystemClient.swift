import Foundation
import WallumeCore

/// The narrow boundary between application synchronization and lock-screen system effects.
public protocol LockScreenSystemClient: Sendable {
    func probe() throws -> LockScreenProbeReport
    func install(media: MediaItem, aerialID: String) throws -> LockScreenTransactionManifest
    func inspectRecovery() throws -> [RecoveryCandidate]
    func restore(transactionID: UUID) throws -> RecoveryReport
}

/// Isolated system boundary for macOS 26's user-level Aerial registration experiment.
///
/// It is intentionally separate from `LockScreenSystemClient`: the older workflow overwrites a
/// selected Apple slot and is prohibited on Tahoe, whereas this workflow creates an owned asset
/// that can be reset independently. The product UI must not expose this path unless a future
/// supported system entry point passes full real-lock-screen acceptance.
public protocol TahoeLockScreenSystemClient: Sendable {
    func installTahoe(
        media: MediaItem,
        assetID: String,
        targetDisplayID: String
    ) async throws -> TahoeAerialTransactionManifest
    func inspectTahoeRecovery() throws -> [TahoeAerialRecoveryCandidate]
    func resetTahoe(transactionID: UUID) throws -> TahoeAerialResetReport
}

public enum LockScreenSystemClientError: Error, Equatable, Sendable {
    case generatedUID(GeneratedUIDProviderError)
}

/// The production implementation of `LockScreenSystemClient`.
///
/// It deliberately composes the Core filesystem and process implementations only at this edge;
/// application synchronization can instead depend on `LockScreenSystemClient` and provide fakes.
public struct ProcessLockScreenSystemClient: LockScreenSystemClient, TahoeLockScreenSystemClient {
    private let homeDirectory: URL
    private let generatedUIDProvider: any GeneratedUIDProviding
    private let systemVersion: OperatingSystemVersion

    public init(
        homeDirectory: URL,
        generatedUIDProvider: any GeneratedUIDProviding,
        systemVersion: OperatingSystemVersion
    ) {
        self.homeDirectory = homeDirectory
        self.generatedUIDProvider = generatedUIDProvider
        self.systemVersion = systemVersion
    }

    /// The sole production factory for the process-backed GeneratedUID provider.
    public static func makeProduction(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> ProcessLockScreenSystemClient {
        ProcessLockScreenSystemClient(
            homeDirectory: homeDirectory,
            generatedUIDProvider: ProcessGeneratedUIDProvider(),
            systemVersion: systemVersion
        )
    }

    public func probe() throws -> LockScreenProbeReport {
        try LockScreenProbe(files: LocalFileStore()).inspect(
            paths: try paths(),
            version: systemVersion
        )
    }

    public func install(media: MediaItem, aerialID: String) throws -> LockScreenTransactionManifest {
        let paths = try paths()
        let files = LocalFileStore()
        let transaction = LockScreenTransaction(
            paths: paths,
            files: files,
            digester: SHA256Digester(),
            journals: AtomicJSONStore(files: files),
            discovery: AerialDiscovery(files: files),
            patcher: WallpaperIndexPatcher(),
            refresher: ProcessWallpaperRefresher()
        )
        return try transaction.install(
            Self.transactionRequest(media: media, aerialID: aerialID, systemVersion: systemVersion)
        )
    }

    public func inspectRecovery() throws -> [RecoveryCandidate] {
        let placeholderPaths = AerialPaths(homeDirectory: homeDirectory, userGeneratedID: "UNKNOWN")
        var candidates: [RecoveryCandidate] = []
        // Tahoe uses a different, additive transaction format. Legacy journals on a Tahoe
        // machine came from the old slot-overwrite implementation and must never block the new
        // registration mode; they remain available through wallume-restore for explicit repair.
        if systemVersion.majorVersion != 26,
           FileManager.default.fileExists(atPath: placeholderPaths.transactionsDirectory.path) {
            let paths = try paths()
            let files = LocalFileStore()
            candidates = try RecoveryCoordinator(
                paths: paths,
                files: files,
                digester: SHA256Digester(),
                journals: AtomicJSONStore(files: files),
                patcher: WallpaperIndexPatcher(),
                refresher: ProcessWallpaperRefresher()
            ).inspect()
        }
        if systemVersion.majorVersion == 26 {
            candidates += try inspectTahoeRecovery().map {
                RecoveryCandidate(id: $0.id, phase: $0.phase, aerialID: $0.assetID, createdAt: $0.createdAt)
            }
        }
        return candidates.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func restore(transactionID: UUID) throws -> RecoveryReport {
        if systemVersion.majorVersion == 26,
           try inspectTahoeRecovery().contains(where: { $0.id == transactionID }) {
            let report = try resetTahoe(transactionID: transactionID)
            return RecoveryReport(restored: report.restored, conflicts: report.conflicts, retainedBackups: [])
        }
        let paths = try paths()
        let files = LocalFileStore()
        return try RecoveryCoordinator(
            paths: paths,
            files: files,
            digester: SHA256Digester(),
            journals: AtomicJSONStore(files: files),
            patcher: WallpaperIndexPatcher(),
            refresher: ProcessWallpaperRefresher()
        ).restore(id: transactionID)
    }

    public func installTahoe(
        media: MediaItem,
        assetID: String,
        targetDisplayID: String
    ) async throws -> TahoeAerialTransactionManifest {
        let paths = try paths()
        // The desktop variant must never be installed directly for Tahoe.  Prepare and validate
        // a separate Main10/240fps copy first; until this succeeds no manifest, index, or system
        // setting is touched.  The staging directory is private app data and is always removed.
        let stagingDirectory = paths.applicationSupport.appending(path: "LockScreen/tahoe-staging")
        let preparedVideo = stagingDirectory.appending(path: "\(assetID).mov")
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: preparedVideo) }
        try await TahoeLockScreenVideoPreparer().prepare(
            source: media.variantURL,
            destination: preparedVideo
        )

        let files = LocalFileStore()
        return try TahoeAerialTransaction(
            paths: paths,
            files: files,
            digester: SHA256Digester(),
            journals: AtomicJSONStore(files: files),
            registrations: TahoeAerialRegistrationStore(
                directory: paths.tahoeRegistrationsDirectory,
                files: files,
                journals: AtomicJSONStore(files: files)
            ),
            refresher: ProcessWallpaperRefresher(),
            screenSaverModule: CurrentHostScreenSaverModuleConfiguration(),
            thumbnailRenderer: PNGTahoeThumbnailRenderer()
        ).install(
            TahoeAerialTransactionRequest(
                id: assetID,
                displayName: media.displayName,
                optimizedVideo: preparedVideo,
                thumbnail: media.coverURL,
                targetDisplayID: targetDisplayID
            )
        )
    }

    public func inspectTahoeRecovery() throws -> [TahoeAerialRecoveryCandidate] {
        let paths = try paths()
        let files = LocalFileStore()
        return try TahoeAerialTransaction(
            paths: paths,
            files: files,
            digester: SHA256Digester(),
            journals: AtomicJSONStore(files: files),
            registrations: TahoeAerialRegistrationStore(
                directory: paths.tahoeRegistrationsDirectory,
                files: files,
                journals: AtomicJSONStore(files: files)
            ),
            refresher: ProcessWallpaperRefresher(),
            screenSaverModule: CurrentHostScreenSaverModuleConfiguration()
        ).inspectRecovery()
    }

    public func resetTahoe(transactionID: UUID) throws -> TahoeAerialResetReport {
        let paths = try paths()
        let files = LocalFileStore()
        return try TahoeAerialTransaction(
            paths: paths,
            files: files,
            digester: SHA256Digester(),
            journals: AtomicJSONStore(files: files),
            registrations: TahoeAerialRegistrationStore(
                directory: paths.tahoeRegistrationsDirectory,
                files: files,
                journals: AtomicJSONStore(files: files)
            ),
            refresher: ProcessWallpaperRefresher(),
            screenSaverModule: CurrentHostScreenSaverModuleConfiguration()
        ).reset(id: transactionID)
    }

    static func transactionRequest(
        media: MediaItem,
        aerialID: String,
        systemVersion: OperatingSystemVersion
    ) -> LockScreenTransactionRequest {
        LockScreenTransactionRequest(
            systemVersion: systemVersion,
            aerialID: aerialID,
            optimizedVideo: media.variantURL,
            poster: media.coverURL
        )
    }

    private func paths() throws -> AerialPaths {
        let generatedUID: String
        do {
            generatedUID = try generatedUIDProvider.generatedUID(for: homeDirectory)
        } catch let error as GeneratedUIDProviderError {
            throw LockScreenSystemClientError.generatedUID(error)
        } catch {
            throw LockScreenSystemClientError.generatedUID(.commandFailed)
        }
        return AerialPaths(homeDirectory: homeDirectory, userGeneratedID: generatedUID)
    }
}
