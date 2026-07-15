import Foundation

public enum MediaLibraryError: Error, Equatable {
    case unsafeArtifact(URL)
}

public struct MediaLibrary: Sendable {
    private let paths: MediaPaths
    private let files: any FileStore
    private let jsonStore: AtomicJSONStore

    private var pathSafety: PathSafetyValidator { PathSafetyValidator(files: files) }

    public init(paths: MediaPaths, files: any FileStore, jsonStore: AtomicJSONStore) {
        self.paths = paths
        self.files = files
        self.jsonStore = jsonStore
    }

    public func find(sourceHash: String) throws -> MediaItem? {
        try loadDocument().items.first { $0.sourceHash == sourceHash }
    }

    public func list() throws -> [MediaItem] {
        try loadDocument().items
    }

    public func item(id: UUID) throws -> MediaItem? {
        try loadDocument().items.first { $0.id == id }
    }

    public func register(_ item: MediaItem) throws {
        var document = try loadDocument()
        guard document.items.allSatisfy({ $0.sourceHash != item.sourceHash }) else { return }
        document.items.append(item)
        try jsonStore.write(document, to: paths.libraryIndex)
    }

    public func remove(id: UUID) throws {
        var document = try loadDocument()
        guard let item = document.items.first(where: { $0.id == id }) else {
            throw MediaImportError.notFound(id)
        }
        try removeOwnedArtifacts(for: item)
        document.items.removeAll { $0.id == id }
        try jsonStore.write(document, to: paths.libraryIndex)
    }

    private func loadDocument() throws -> MediaLibraryDocument {
        guard files.exists(paths.libraryIndex) else { return MediaLibraryDocument() }
        return try jsonStore.read(MediaLibraryDocument.self, from: paths.libraryIndex)
    }

    private func removeOwnedArtifacts(for item: MediaItem) throws {
        let artifacts = [
            (item.variantURL, paths.variantsDirectory),
            (item.thumbnailURL, paths.thumbnailsDirectory),
            (item.coverURL, paths.coversDirectory),
        ]

        for (artifact, root) in artifacts {
            guard isUnderOwnedRoot(artifact, root: root),
                  try pathSafety.accepts(artifact, as: .regularFileIfPresent) else {
                throw MediaLibraryError.unsafeArtifact(artifact)
            }
        }

        for (artifact, _) in artifacts where files.exists(artifact) {
            let identity = try files.identity(of: artifact)
            guard try files.removeDurably(artifact, ifIdentityMatches: identity) else {
                throw MediaLibraryError.unsafeArtifact(artifact)
            }
        }
    }

    private func isUnderOwnedRoot(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.pathComponents
        let rootPath = root.standardizedFileURL.pathComponents
        return path.count > rootPath.count && path.starts(with: rootPath)
    }
}
