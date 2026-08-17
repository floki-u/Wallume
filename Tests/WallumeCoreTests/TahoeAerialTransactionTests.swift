import Foundation
import XCTest
@testable import WallumeCore

final class TahoeAerialTransactionTests: XCTestCase {
    func testInstallRegistersNewAssetAndResetPreservesForeignManifestChanges() throws {
        let fixture = try TahoeFixture()
        let transaction = fixture.transaction()
        let request = fixture.request(id: "BD000000-0000-4000-8000-000000000001")

        let installed = try transaction.install(request)
        let video = fixture.paths.videosDirectory.appending(path: "\(request.id).mov")
        XCTAssertTrue(fixture.files.exists(video))
        let attributes = try FileManager.default.attributesOfItem(atPath: video.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        XCTAssertEqual(try fixture.registrations.registrations(), [installed.registration])
        XCTAssertEqual(try fixture.selectedAerialID(), request.id)

        let foreign = TahoeAerialAsset(
            id: "BD000000-0000-4000-8000-000000000099",
            displayName: "Foreign",
            localVideoURL: fixture.paths.videosDirectory.appending(path: "foreign.mov"),
            localThumbnailURL: fixture.paths.thumbnailsDirectory.appending(path: "foreign.jpg")
        )
        let current = try fixture.files.read(fixture.paths.manifest)
        try fixture.files.writeAtomically(try TahoeAerialCatalog().register(foreign, in: current), to: fixture.paths.manifest)

        let report = try transaction.reset(id: installed.id)

        XCTAssertTrue(report.conflicts.isEmpty)
        XCTAssertTrue(report.restored.contains(video))
        XCTAssertFalse(fixture.files.exists(video))
        XCTAssertTrue(try fixture.registrations.registrations().isEmpty)
        XCTAssertEqual(try fixture.manifestAssetIDs(), [foreign.id])
        XCTAssertEqual(try fixture.selectedAerialID(), "Apple-Aerial")
        XCTAssertFalse(fixture.files.exists(fixture.journalURL(installed.id)))
    }

    func testResetRetainsExternallyChangedMovieAndCanBeRetried() throws {
        let fixture = try TahoeFixture()
        let transaction = fixture.transaction()
        let installed = try transaction.install(fixture.request(id: "BD000000-0000-4000-8000-000000000001"))
        let video = installed.registration.asset.videoURL
        try fixture.files.writeAtomically(Data("external movie".utf8), to: video)

        let first = try transaction.reset(id: installed.id)

        XCTAssertEqual(first.conflicts, [video])
        XCTAssertTrue(fixture.files.exists(fixture.journalURL(installed.id)))
        XCTAssertEqual(try fixture.registrations.registrations(), [installed.registration])

        try fixture.files.writeAtomically(Data("video".utf8), to: video)
        let second = try transaction.reset(id: installed.id)

        XCTAssertTrue(second.conflicts.isEmpty)
        XCTAssertFalse(fixture.files.exists(video))
        XCTAssertFalse(fixture.files.exists(fixture.journalURL(installed.id)))
    }

    func testInstallActivatesOnlyAerialScreenSaverModuleAndResetRestoresPriorValue() throws {
        let fixture = try TahoeFixture()
        let screenSaver = TahoeTestScreenSaverModule()
        let transaction = fixture.transaction(screenSaverModule: screenSaver)

        let installed = try transaction.install(fixture.request(id: "BD000000-0000-4000-8000-000000000001"))

        XCTAssertTrue(screenSaver.active)
        XCTAssertNotNil(installed.screenSaverModuleBefore?.value)

        _ = try transaction.reset(id: installed.id)

        XCTAssertFalse(screenSaver.active)
        XCTAssertEqual(screenSaver.restoredValue, Data("previous-module".utf8))
    }
}

private final class TahoeFixture {
    let root: URL
    let files = LocalFileStore()
    let paths: AerialPaths
    let registrations: TahoeAerialRegistrationStore
    private let journals: AtomicJSONStore

    init() throws {
        // Path-safety intentionally rejects /var because it is a symlink to /private/var.
        // Use a synthetic home below the real home directory, matching the production shape.
        root = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: ".wallume-test-tahoe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AerialPaths(homeDirectory: root, userGeneratedID: "TEST")
        journals = AtomicJSONStore(files: files)
        registrations = TahoeAerialRegistrationStore(
            directory: paths.tahoeRegistrationsDirectory, files: files, journals: journals
        )
        try files.createDirectory(paths.videosDirectory)
        try files.createDirectory(paths.thumbnailsDirectory)
        try files.writeAtomically(
            try JSONSerialization.data(withJSONObject: ["version": 1, "categories": [], "assets": []], options: [.sortedKeys]),
            to: paths.manifest
        )
        try files.writeAtomically(try indexData(assetID: "Apple-Aerial"), to: paths.wallpaperIndex)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func transaction(screenSaverModule: any ScreenSaverModuleConfiguring = NoopScreenSaverModuleConfiguration()) -> TahoeAerialTransaction {
        TahoeAerialTransaction(
            paths: paths,
            files: files,
            digester: SHA256Digester(),
            journals: journals,
            registrations: registrations,
            refresher: TahoeNoopRefresher(),
            screenSaverModule: screenSaverModule,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeID: { UUID(uuidString: "BD000000-0000-4000-8000-000000000010")! }
        )
    }

    func request(id: String) -> TahoeAerialTransactionRequest {
        let source = root.appending(path: "source-\(id).mov")
        let thumbnail = root.appending(path: "source-\(id).jpg")
        try! files.writeAtomically(Data("video".utf8), to: source)
        try! files.writeAtomically(Data("thumbnail".utf8), to: thumbnail)
        return TahoeAerialTransactionRequest(
            id: id,
            displayName: "Aurora",
            optimizedVideo: source,
            thumbnail: thumbnail,
            targetDisplayID: "cg-uuid:37D8832A-2D66-02CA-B9F7-8F30A301B230"
        )
    }

    func journalURL(_ id: UUID) -> URL {
        paths.tahoeTransactionsDirectory.appending(path: "\(id.uuidString).json")
    }

    func manifestAssetIDs() throws -> [String] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: files.read(paths.manifest)) as? [String: Any])
        return try XCTUnwrap(root["assets"] as? [[String: Any]]).compactMap { $0["id"] as? String }
    }

    func selectedAerialID() throws -> String {
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: files.read(paths.wallpaperIndex), format: nil) as? [String: Any])
        let displays = try XCTUnwrap(root["Displays"] as? [String: Any])
        let display = try XCTUnwrap(displays["37D8832A-2D66-02CA-B9F7-8F30A301B230"] as? [String: Any])
        let idle = try XCTUnwrap(display["Idle"] as? [String: Any])
        let content = try XCTUnwrap(idle["Content"] as? [String: Any])
        let choices = try XCTUnwrap(content["Choices"] as? [[String: Any]])
        let configuration = try XCTUnwrap(choices.first?["Configuration"] as? Data)
        let value = try XCTUnwrap(PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any])
        return try XCTUnwrap(value["assetID"] as? String)
    }

    private func indexData(assetID: String) throws -> Data {
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID],
            format: .binary,
            options: 0
        )
        return try PropertyListSerialization.data(
            fromPropertyList: [
                "Displays": [
                    "37D8832A-2D66-02CA-B9F7-8F30A301B230": [
                        "Idle": [
                            "Content": [
                                "Choices": [[
                                    "Provider": "com.apple.wallpaper.choice.aerials",
                                    "Configuration": configuration,
                                ]],
                            ],
                            "LastSet": Date(timeIntervalSince1970: 1),
                            "LastUse": Date(timeIntervalSince1970: 1),
                        ],
                    ],
                ],
            ],
            format: .binary,
            options: 0
        )
    }
}

private struct TahoeNoopRefresher: WallpaperRefreshing {
    func refresh() throws {}
}

private final class TahoeTestScreenSaverModule: ScreenSaverModuleConfiguring, @unchecked Sendable {
    private(set) var active = false
    private(set) var restoredValue: Data?

    func snapshot() throws -> ScreenSaverModuleSnapshot {
        ScreenSaverModuleSnapshot(value: Data("previous-module".utf8))
    }

    func activateWallpaperAerials() throws { active = true }
    func isWallpaperAerialsActive() throws -> Bool { active }

    func restore(_ snapshot: ScreenSaverModuleSnapshot) throws {
        active = false
        restoredValue = snapshot.value
    }
}
