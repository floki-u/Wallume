import Foundation

public struct MediaInspection: Sendable, Equatable {
    public let sourceByteCount: Int64
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameRate: Double
    public let durationSeconds: Double
    public let codec: String

    public init(
        sourceByteCount: Int64,
        pixelWidth: Int,
        pixelHeight: Int,
        frameRate: Double,
        durationSeconds: Double,
        codec: String
    ) {
        self.sourceByteCount = sourceByteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameRate = frameRate
        self.durationSeconds = durationSeconds
        self.codec = codec
    }
}

public enum MediaTranscodePolicy: Sendable, Equatable {
    case singleVariant
}

public protocol MediaInspecting: Sendable {
    func inspect(_ url: URL) async throws -> MediaInspection
}

public protocol MediaTranscoding: Sendable {
    func transcode(
        _ source: URL,
        to destination: URL,
        policy: MediaTranscodePolicy,
        progress: (@Sendable (Double) -> Void)?
    ) async throws
}

public extension MediaTranscoding {
    func transcode(_ source: URL, to destination: URL, policy: MediaTranscodePolicy) async throws {
        try await transcode(source, to: destination, policy: policy, progress: nil)
    }
}

public enum MediaImportStage: String, CaseIterable, Equatable, Sendable {
    case hashing
    case inspecting
    case transcoding
    case artwork
    case committing
    case cleanup
}

public enum MediaImportEvent: Equatable, Sendable {
    case stage(MediaImportStage, progress: Double?)

    public var stage: MediaImportStage? {
        guard case let .stage(stage, progress) = self, progress == nil else { return nil }
        return stage
    }
}

public protocol ArtworkGenerating: Sendable {
    func generateArtwork(for variant: URL, thumbnail: URL, cover: URL) async throws
}

public struct MediaImportResult: Sendable, Equatable {
    public let source: URL
    public let status: MediaImportStatus
    public let item: MediaItem?
    public let message: String?

    public init(source: URL, status: MediaImportStatus, item: MediaItem? = nil, message: String? = nil) {
        self.source = source
        self.status = status
        self.item = item
        self.message = message
    }
}

public struct MediaImportReport: Sendable, Equatable {
    public let results: [MediaImportResult]

    public init(results: [MediaImportResult]) {
        self.results = results
    }
}

public actor MediaImporter {
    private let paths: MediaPaths
    private let files: any FileStore
    private let library: MediaLibrary
    private let digester: any Digesting
    private let inspector: any MediaInspecting
    private let transcoder: any MediaTranscoding
    private let artwork: any ArtworkGenerating
    private let idGenerator: @Sendable () -> UUID
    private let date: @Sendable () -> Date

    public init(
        paths: MediaPaths,
        files: any FileStore,
        library: MediaLibrary,
        digester: any Digesting = SHA256Digester(),
        inspector: any MediaInspecting,
        transcoder: any MediaTranscoding,
        artwork: any ArtworkGenerating,
        idGenerator: @escaping @Sendable () -> UUID = UUID.init,
        date: @escaping @Sendable () -> Date = Date.init
    ) {
        self.paths = paths
        self.files = files
        self.library = library
        self.digester = digester
        self.inspector = inspector
        self.transcoder = transcoder
        self.artwork = artwork
        self.idGenerator = idGenerator
        self.date = date
    }

    public func importURLs(_ urls: [URL]) async throws -> MediaImportReport {
        let candidates = LocalImportScanner().scan(urls).candidates
        var results: [MediaImportResult] = []
        for candidate in candidates {
            results.append(await importURL(candidate) { _ in })
        }
        return MediaImportReport(results: results)
    }

    public func importURL(
        _ source: URL,
        onEvent: @escaping @Sendable (MediaImportEvent) -> Void
    ) async -> MediaImportResult {
        let sourceHash: String
        do {
            try Task.checkCancellation()
            onEvent(.stage(.hashing, progress: nil))
            sourceHash = try digester.sha256(of: source)
            if let existing = try library.find(sourceHash: sourceHash) {
                return MediaImportResult(source: source, status: .duplicate, item: existing)
            }
        } catch {
            return MediaImportResult(source: source, status: .failed, message: String(describing: error))
        }

        let id = idGenerator()
        let workDirectory = paths.importWork(id: id)
        let stagedVariant = workDirectory.appending(path: "variant.mov")
        let stagedThumbnail = workDirectory.appending(path: "thumbnail.jpg")
        let stagedCover = workDirectory.appending(path: "cover.jpg")
        let installedVariant = paths.variant(id: id)
        let installedThumbnail = paths.thumbnail(id: id)
        let installedCover = paths.cover(id: id)

        do {
            try Task.checkCancellation()
            try files.createDirectory(paths.importWorkRoot)
            try files.createPrivateDirectory(workDirectory)
            onEvent(.stage(.inspecting, progress: nil))
            let sourceInspection = try await inspector.inspect(source)
            try Task.checkCancellation()
            onEvent(.stage(.transcoding, progress: nil))
            try await transcoder.transcode(
                source,
                to: stagedVariant,
                policy: .singleVariant
            ) { progress in
                onEvent(.stage(.transcoding, progress: min(max(progress, 0), 1)))
            }
            try Task.checkCancellation()
            let variantInspection = try await inspector.inspect(stagedVariant)
            onEvent(.stage(.artwork, progress: nil))
            try await artwork.generateArtwork(for: stagedVariant, thumbnail: stagedThumbnail, cover: stagedCover)
            try Task.checkCancellation()
            onEvent(.stage(.committing, progress: nil))
            try verifyStagedArtifacts([stagedVariant, stagedThumbnail, stagedCover])
            try files.createDirectory(installedVariant.deletingLastPathComponent())
            try files.createDirectory(installedThumbnail.deletingLastPathComponent())
            try files.createDirectory(installedCover.deletingLastPathComponent())
            try files.installExclusively(installedVariant, from: stagedVariant)
            try files.installExclusively(installedThumbnail, from: stagedThumbnail)
            try files.installExclusively(installedCover, from: stagedCover)
            let item = MediaItem(
                id: id,
                sourceHash: sourceHash,
                sourceURL: source,
                displayName: source.deletingPathExtension().lastPathComponent,
                sourceByteCount: sourceInspection.sourceByteCount,
                pixelWidth: variantInspection.pixelWidth,
                pixelHeight: variantInspection.pixelHeight,
                frameRate: variantInspection.frameRate,
                durationSeconds: variantInspection.durationSeconds,
                codec: variantInspection.codec,
                variantURL: installedVariant,
                thumbnailURL: installedThumbnail,
                coverURL: installedCover,
                createdAt: date()
            )
            try library.register(item)
            onEvent(.stage(.cleanup, progress: nil))
            try removeIfPresent(workDirectory)
            return MediaImportResult(source: source, status: .imported, item: item)
        } catch is CancellationError {
            onEvent(.stage(.cleanup, progress: nil))
            do {
                try cleanup(workDirectory: workDirectory, installed: [installedVariant, installedThumbnail, installedCover])
                return MediaImportResult(source: source, status: .cancelled)
            } catch {
                return MediaImportResult(source: source, status: .failed, message: String(describing: error))
            }
        } catch {
            let importError = error
            onEvent(.stage(.cleanup, progress: nil))
            do {
                try cleanup(workDirectory: workDirectory, installed: [installedVariant, installedThumbnail, installedCover])
                return MediaImportResult(source: source, status: .failed, message: String(describing: importError))
            } catch {
                return MediaImportResult(
                    source: source,
                    status: .failed,
                    message: "\(importError); cleanup: \(error)"
                )
            }
        }
    }

    private func verifyStagedArtifacts(_ urls: [URL]) throws {
        let safety = PathSafetyValidator(files: files)
        for url in urls {
            guard try safety.accepts(url, as: .existingRegularFile) else {
                throw MediaImportError.notFound(UUID())
            }
        }
    }

    private func cleanup(workDirectory: URL, installed: [URL]) throws {
        for url in installed {
            try removeIfPresent(url)
        }
        try removeDirectoryTreeIfPresent(workDirectory)
    }

    private func removeIfPresent(_ url: URL) throws {
        guard files.exists(url) else { return }
        let identity = try files.identity(of: url)
        _ = try files.removeDurably(url, ifIdentityMatches: identity)
    }

    private func removeDirectoryTreeIfPresent(_ directory: URL) throws {
        guard files.exists(directory) else { return }
        for child in try files.contents(directory) {
            try removeIfPresent(child)
        }
        try removeIfPresent(directory)
    }
}
