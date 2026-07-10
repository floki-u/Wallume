import Foundation
import XCTest
@testable import WallumeCore

final class AerialDiscoveryTests: XCTestCase {
    func testOnlyManifestBackedMovFilesAreOffered() throws {
        let fixture = try AerialFixture.make()
        defer { fixture.remove() }
        try fixture.writeVideo(id: "AERIAL-ONE")
        try fixture.writeVideo(id: "UNLISTED")

        let slots = try fixture.discovery.availableSlots(paths: fixture.paths)

        XCTAssertEqual(slots.map(\.id), ["AERIAL-ONE"])
        XCTAssertEqual(slots.first?.displayName, "Test Coast")
    }

    func testSelectionRequiresExactIDAndRejectsForeignBackup() throws {
        let fixture = try AerialFixture.make()
        defer { fixture.remove() }
        try fixture.writeVideo(id: "AERIAL-ONE")
        try Data("foreign".utf8).write(
            to: fixture.paths.videosDirectory.appending(
                path: "AERIAL-ONE.mov.wallpaper-engine-backup"
            )
        )

        XCTAssertThrowsError(
            try fixture.discovery.selectSlot(id: "AERIAL-ONE", paths: fixture.paths)
        ) {
            XCTAssertEqual(
                $0 as? AerialDiscoveryError,
                .foreignModificationDetected("AERIAL-ONE")
            )
        }
        XCTAssertThrowsError(
            try fixture.discovery.selectSlot(id: "aerial-one", paths: fixture.paths)
        ) {
            XCTAssertEqual($0 as? AerialDiscoveryError, .slotNotFound("aerial-one"))
        }
        XCTAssertThrowsError(
            try fixture.discovery.selectSlot(id: "MISSING", paths: fixture.paths)
        ) {
            XCTAssertEqual($0 as? AerialDiscoveryError, .slotNotFound("MISSING"))
        }
    }

    func testSelectionAllowsOnlyWallumesExactBackupMarker() throws {
        let fixture = try AerialFixture.make()
        defer { fixture.remove() }
        try fixture.writeVideo(id: "AERIAL-ONE")
        let videoName = "AERIAL-ONE.mov"
        try Data("wallume".utf8).write(
            to: fixture.paths.videosDirectory.appending(
                path: videoName + WallumeBuildInfo.backupMarker
            )
        )

        let slot = try fixture.discovery.selectSlot(id: "AERIAL-ONE", paths: fixture.paths)

        XCTAssertEqual(slot.id, "AERIAL-ONE")

        try Data("foreign".utf8).write(
            to: fixture.paths.videosDirectory.appending(
                path: videoName + ".fake-" + WallumeBuildInfo.bundleIdentifier
            )
        )
        XCTAssertThrowsError(
            try fixture.discovery.selectSlot(id: "AERIAL-ONE", paths: fixture.paths)
        ) {
            XCTAssertEqual(
                $0 as? AerialDiscoveryError,
                .foreignModificationDetected("AERIAL-ONE")
            )
        }
    }
}

private struct AerialFixture {
    let root: URL
    let paths: AerialPaths
    let discovery: AerialDiscovery

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Wallume-AerialDiscoveryTests-\(UUID().uuidString)")
        let paths = AerialPaths(homeDirectory: root, userGeneratedID: "TEST-USER")
        try FileManager.default.createDirectory(
            at: paths.videosDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: paths.manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let manifestFixture = Bundle.module.url(
            forResource: "entries",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.missingManifest
        }
        try FileManager.default.copyItem(at: manifestFixture, to: paths.manifest)
        return Self(root: root, paths: paths, discovery: AerialDiscovery(files: LocalFileStore()))
    }

    func writeVideo(id: String) throws {
        try Data("video".utf8).write(
            to: paths.videosDirectory.appending(path: "\(id).mov")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private enum FixtureError: Error {
        case missingManifest
    }
}
