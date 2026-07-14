import Foundation
import XCTest
@testable import WallumeCore

final class LockScreenProbeTests: XCTestCase {
    func testUnknownVersionReportsReadOnlyAndNeverCreatesDirectories() throws {
        let fixture = try ProbeFixture.make()
        defer { fixture.remove() }

        let report = try LockScreenProbe(files: LocalFileStore()).inspect(
            paths: fixture.paths,
            version: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )

        XCTAssertFalse(report.writesPermitted)
        XCTAssertEqual(report.generation, .unsupported(27))
        XCTAssertTrue(report.manifestExists)
        XCTAssertFalse(report.indexExists)
        XCTAssertEqual(report.availableSlots.map(\.id), [])
        XCTAssertFalse(LocalFileStore().exists(fixture.paths.transactionsDirectory))
    }

    func testProbeReportsSlotsAndForeignBackupNamesWithoutRejectingTheReport() throws {
        let fixture = try ProbeFixture.make()
        defer { fixture.remove() }
        try fixture.writeVideo(id: "AERIAL-ONE")
        try fixture.writeVideo(id: "AERIAL-TWO")
        try Data("foreign".utf8).write(
            to: fixture.paths.videosDirectory.appending(path: "AERIAL-ONE.mov.some-other-backup")
        )
        try Data("wallume".utf8).write(
            to: fixture.paths.videosDirectory.appending(
                path: "AERIAL-TWO.mov\(WallumeBuildInfo.backupMarker)"
            )
        )
        try Data("index".utf8).write(to: fixture.paths.wallpaperIndex)

        let report = try LockScreenProbe(files: LocalFileStore()).inspect(
            paths: fixture.paths,
            version: .init(majorVersion: 26, minorVersion: 5, patchVersion: 2)
        )

        XCTAssertTrue(report.writesPermitted)
        XCTAssertEqual(report.generation, .tahoe)
        XCTAssertTrue(report.indexExists)
        XCTAssertEqual(report.availableSlots.map(\.id), ["AERIAL-ONE", "AERIAL-TWO"])
        XCTAssertEqual(report.foreignBackupNames, ["AERIAL-ONE.mov.some-other-backup"])
    }
}

private struct ProbeFixture {
    let root: URL
    let paths: AerialPaths

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Wallume-ProbeTests-\(UUID().uuidString)")
        let paths = AerialPaths(homeDirectory: root, userGeneratedID: "TEST-USER")
        try FileManager.default.createDirectory(
            at: paths.videosDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: paths.manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: paths.wallpaperIndex.deletingLastPathComponent(),
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
        return Self(root: root, paths: paths)
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
