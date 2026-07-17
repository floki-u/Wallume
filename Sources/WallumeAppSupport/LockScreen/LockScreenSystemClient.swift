import Foundation
import WallumeCore

/// The narrow boundary between application synchronization and lock-screen system effects.
public protocol LockScreenSystemClient: Sendable {
    func probe() throws -> LockScreenProbeReport
    func install(media: MediaItem, aerialID: String) throws -> LockScreenTransactionManifest
    func inspectRecovery() throws -> [RecoveryCandidate]
    func restore(transactionID: UUID) throws -> RecoveryReport
}

public enum LockScreenSystemClientError: Error, Equatable, Sendable {
    case generatedUID(GeneratedUIDProviderError)
}

/// The production implementation of `LockScreenSystemClient`.
///
/// It deliberately composes the Core filesystem and process implementations only at this edge;
/// application synchronization can instead depend on `LockScreenSystemClient` and provide fakes.
public struct ProcessLockScreenSystemClient: LockScreenSystemClient {
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
        guard FileManager.default.fileExists(atPath: placeholderPaths.transactionsDirectory.path) else {
            return []
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
        ).inspect()
    }

    public func restore(transactionID: UUID) throws -> RecoveryReport {
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
