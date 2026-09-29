import Foundation
import XCTest
@testable import WallumeCore

final class StaticImageMediaTests: XCTestCase {
    func testImportScannerFindsSupportedImagesAndVideos() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["a.png", "b.JPG", "c.jpeg", "d.heic", "e.mov", "f.mp4", "ignored.txt"] {
            FileManager.default.createFile(
                atPath: root.appending(path: name).path,
                contents: Data([0x01])
            )
        }

        let names = LocalImportScanner().scan([root]).candidates.map(\.lastPathComponent)
        XCTAssertEqual(names, ["a.png", "b.JPG", "c.jpeg", "d.heic", "e.mov", "f.mp4"])
    }

    func testLegacyMediaItemWithoutKindDecodesAsVideo() throws {
        let original = makeMedia(kind: .video)
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "kind")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(MediaItem.self, from: legacyData)

        XCTAssertEqual(decoded.kind, .video)
    }

    func testLegacyLibraryDocumentMigratesToCurrentSchema() throws {
        let encoded = try JSONEncoder().encode(MediaLibraryDocument(items: [makeMedia(kind: .video)]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 2
        var items = try XCTUnwrap(object["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "kind")
        object["items"] = items
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(MediaLibraryDocument.self, from: legacyData)

        XCTAssertEqual(decoded.schemaVersion, MediaLibraryDocument.currentSchemaVersion)
        XCTAssertEqual(decoded.items.first?.kind, .video)
    }

    func testImageRuntimeSessionDoesNotCreatePlaybackResource() async throws {
        let media = makeMedia(kind: .image)
        let factory = RecordingPlayerFactory()
        let coordinator = RuntimeCoordinator(
            catalog: StubMediaCatalog(items: [media.id: media]),
            pool: PlayerPool(factory: factory)
        )
        let display = DisplayID("display")

        let snapshot = await coordinator.reconcile(
            displays: [display],
            assignments: [RuntimeAssignment(displayID: display, mediaID: media.id)],
            environment: .active
        )

        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertNil(snapshot.sessions.first?.resourceID)
        XCTAssertEqual(factory.makeCount, 0)
    }

    @MainActor
    func testDesktopWindowPresentsOriginalImageWithoutPlayback() throws {
        let media = makeMedia(kind: .image)
        let display = DisplayID("display")
        let surface = RecordingDesktopSurface()
        let controller = DesktopWindowController(factory: RecordingDesktopSurfaceFactory(surface: surface))
        _ = controller.reconcile([DesktopScreen(id: display, frame: CGRect(x: 0, y: 0, width: 800, height: 600))])
        let snapshot = RuntimeSnapshot(
            sessions: [RuntimeDisplaySession(displayID: display, mediaID: media.id, resourceID: nil)],
            resourceReferenceCounts: [:],
            pauseReasons: [],
            failures: [],
            resourceCreationCount: 0
        )

        let failures = controller.apply(snapshot: snapshot, mediaByID: [media.id: media])

        XCTAssertTrue(failures.isEmpty)
        XCTAssertNil(surface.presentation)
        XCTAssertEqual(surface.fallbackURL, media.variantURL)
        XCTAssertEqual(surface.mode, .fill)
    }

    func testImageProcessorReadsDimensionsAndCreatesArtwork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "pixel.png")
        let thumbnail = root.appending(path: "thumbnail.jpg")
        let cover = root.appending(path: "cover.jpg")
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z7rQAAAAASUVORK5CYII="
        ))
        try png.write(to: source)
        let processor = ImageIOMediaProcessor()

        let inspection = try await processor.inspect(source)
        try await processor.generateArtwork(for: source, thumbnail: thumbnail, cover: cover)

        XCTAssertEqual(inspection.pixelWidth, 1)
        XCTAssertEqual(inspection.pixelHeight, 1)
        XCTAssertEqual(inspection.frameRate, 0)
        XCTAssertEqual(inspection.durationSeconds, 0)
        XCTAssertEqual(inspection.codec, "PNG")
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cover.path))
    }

    func testImageImportPreservesOriginalAndRegistersStaticMedia() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let cache = root.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "wallpaper.png")
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z7rQAAAAASUVORK5CYII="
        ))
        try png.write(to: source)
        let files = LocalFileStore()
        let paths = MediaPaths(homeDirectory: home, cacheDirectory: cache)
        let library = MediaLibrary(paths: paths, files: files, jsonStore: AtomicJSONStore(files: files))
        let importer = MediaImporter(
            paths: paths,
            files: files,
            library: library,
            inspector: UnexpectedVideoInspector(),
            transcoder: UnexpectedVideoTranscoder(),
            artwork: UnexpectedVideoArtworkGenerator()
        )

        let result = await importer.importURL(source) { _ in }
        XCTAssertEqual(result.status, .imported, result.message ?? "")
        let item = try XCTUnwrap(result.item)

        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.variantURL.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: item.variantURL), png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.thumbnailURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.coverURL.path))
        XCTAssertEqual(try library.list().first?.kind, .image)

        try library.remove(id: item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.variantURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.thumbnailURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.coverURL.path))
    }

    private func makeMedia(kind: MediaKind) -> MediaItem {
        let root = URL(fileURLWithPath: "/tmp")
        return MediaItem(
            id: UUID(),
            kind: kind,
            sourceHash: "hash",
            sourceURL: root.appending(path: "source"),
            displayName: "Scene",
            sourceByteCount: 1,
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            frameRate: kind == .video ? 30 : 0,
            durationSeconds: kind == .video ? 5 : 0,
            codec: kind == .video ? "h264" : "png",
            variantURL: root.appending(path: kind == .video ? "variant.mov" : "variant.png"),
            thumbnailURL: root.appending(path: "thumbnail.jpg"),
            coverURL: root.appending(path: "cover.jpg"),
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private struct StubMediaCatalog: MediaCatalog {
    let items: [UUID: MediaItem]
    func item(id: UUID) throws -> MediaItem? { items[id] }
}

private final class RecordingPlayerFactory: PlayerFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var makeCount: Int { lock.withLock { count } }

    func makePlayer(for media: MediaItem) async throws -> any PlaybackResource {
        lock.withLock { count += 1 }
        return NoopPlaybackResource()
    }
}

private final class NoopPlaybackResource: PlaybackResource, @unchecked Sendable {
    let resourceID = UUID()
    func play() async throws {}
    func pause() async throws {}
    func release() async {}
}

private enum UnexpectedVideoDependencyError: Error {
    case called
}

private struct UnexpectedVideoInspector: MediaInspecting {
    func inspect(_ url: URL) async throws -> MediaInspection {
        throw UnexpectedVideoDependencyError.called
    }
}

private struct UnexpectedVideoTranscoder: MediaTranscoding {
    func transcode(
        _ source: URL,
        to destination: URL,
        policy: MediaTranscodePolicy,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        throw UnexpectedVideoDependencyError.called
    }
}

private struct UnexpectedVideoArtworkGenerator: ArtworkGenerating {
    func generateArtwork(for variant: URL, thumbnail: URL, cover: URL) async throws {
        throw UnexpectedVideoDependencyError.called
    }
}

@MainActor
private final class RecordingDesktopSurface: DesktopSurface {
    var presentation: PlaybackPresentation?
    var fallbackURL: URL?
    var mode: WallpaperPresentationMode?

    func show(frame: CGRect) {}

    func setPresentation(
        _ presentation: PlaybackPresentation?,
        fallbackURL: URL?,
        mode: WallpaperPresentationMode
    ) throws {
        self.presentation = presentation
        self.fallbackURL = fallbackURL
        self.mode = mode
    }

    func close() {}
}

@MainActor
private final class RecordingDesktopSurfaceFactory: DesktopSurfaceFactory {
    let surface: RecordingDesktopSurface
    init(surface: RecordingDesktopSurface) { self.surface = surface }
    func makeSurface(for screen: DesktopScreen) throws -> any DesktopSurface { surface }
}
