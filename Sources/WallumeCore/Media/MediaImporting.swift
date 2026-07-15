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
    func transcode(_ source: URL, to destination: URL, policy: MediaTranscodePolicy) async throws
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
        let candidates = try expandAndSort(urls)
        var results: [MediaImportResult] = []
        for candidate in candidates {
            results.append(try await importOne(candidate))
        }
        return MediaImportReport(results: results)
    }

    private func importOne(_ source: URL) async throws -> MediaImportResult {
        let sourceHash: String
        do {
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
            try files.createDirectory(paths.importWorkRoot)
            try files.createPrivateDirectory(workDirectory)
            let sourceInspection = try await inspector.inspect(source)
            try await transcoder.transcode(source, to: stagedVariant, policy: .singleVariant)
            try await artwork.generateArtwork(for: stagedVariant, thumbnail: stagedThumbnail, cover: stagedCover)
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
                pixelWidth: sourceInspection.pixelWidth,
                pixelHeight: sourceInspection.pixelHeight,
                frameRate: sourceInspection.frameRate,
                durationSeconds: sourceInspection.durationSeconds,
                codec: sourceInspection.codec,
                variantURL: installedVariant,
                thumbnailURL: installedThumbnail,
                coverURL: installedCover,
                createdAt: date()
            )
            try library.register(item)
            try removeIfPresent(workDirectory)
            return MediaImportResult(source: source, status: .imported, item: item)
        } catch is CancellationError {
            try cleanup(workDirectory: workDirectory, installed: [installedVariant, installedThumbnail, installedCover])
            return MediaImportResult(source: source, status: .cancelled)
        } catch {
            try cleanup(workDirectory: workDirectory, installed: [installedVariant, installedThumbnail, installedCover])
            return MediaImportResult(source: source, status: .failed, message: String(describing: error))
        }
    }

    private func expandAndSort(_ urls: [URL]) throws -> [URL] {
        var candidates: [URL] = []
        for url in urls {
            try appendCandidates(from: url, to: &candidates)
        }
        return candidates.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func appendCandidates(from url: URL, to candidates: inout [URL]) throws {
        guard files.exists(url) else { return }
        let identity = try files.identity(of: url)
        if identity.isDirectory {
            for child in try files.contents(url) {
                try appendCandidates(from: child, to: &candidates)
            }
        } else if identity.isRegularFile, Self.isSupportedMediaURL(url) {
            candidates.append(url)
        }
    }

    private static func isSupportedMediaURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mp4" || ext == "mov"
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
