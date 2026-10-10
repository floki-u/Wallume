import Foundation
import XCTest
import WallumeCore
@testable import WallumeAppSupport

final class ModernMacOSCompatibilityTests: XCTestCase {
    func testModernProbeUsesSharedStrategyWithoutAllowingLegacyWrites() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }

        for majorVersion in [26, 27, 28] {
            let report = try fixture.client(majorVersion: majorVersion).probe()

            XCTAssertEqual(report.generation, .tahoe)
            XCTAssertFalse(report.writesPermitted)
        }
    }

    func testOlderSystemsRetainTheirProbePolicy() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }

        for majorVersion in [14, 15] {
            XCTAssertTrue(try fixture.client(majorVersion: majorVersion).probe().writesPermitted)
        }
        let unsupported = try fixture.client(majorVersion: 25).probe()
        XCTAssertEqual(unsupported.generation, .unsupported(25))
        XCTAssertFalse(unsupported.writesPermitted)
    }

    func testModernSystemsDiscoverExistingRecoveryWithoutReadingLegacyJournals() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }

        for majorVersion in [26, 27, 28] {
            let candidates = try fixture.client(majorVersion: majorVersion).inspectRecovery()

            XCTAssertEqual(candidates.map(\.id), [fixture.transaction.id])
            XCTAssertEqual(candidates.first?.phase, .restoring)
            XCTAssertEqual(candidates.first?.aerialID, fixture.transaction.registration.asset.id)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.legacyJournal), fixture.legacyData)
    }

    func testModernSystemsFinishInterruptedResetUsingExistingJournal() throws {
        for majorVersion in [26, 27, 28] {
            let fixture = try RecoveryFixture()
            defer { fixture.remove() }

            // The previous reset removed the asset but stopped before deleting its journal.
            // Finishing it must preserve the current wallpaper and avoid a system refresh.
            let report = try fixture.client(majorVersion: majorVersion)
                .restore(transactionID: fixture.transaction.id)

            XCTAssertTrue(report.restored.isEmpty)
            XCTAssertTrue(report.conflicts.isEmpty)
            XCTAssertTrue(report.retainedBackups.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
            XCTAssertEqual(try Data(contentsOf: fixture.paths.manifest), fixture.manifestData)
            XCTAssertEqual(try Data(contentsOf: fixture.paths.wallpaperIndex), fixture.indexData)
            XCTAssertEqual(try Data(contentsOf: fixture.legacyJournal), fixture.legacyData)
        }
    }
}

private struct RecoveryFixture {
    let home = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let paths: AerialPaths
    let transaction: TahoeAerialTransactionManifest
    let journal: URL
    let legacyJournal: URL
    let manifestData = Data(#"{"assets":[]}"#.utf8)
    let indexData: Data
    let legacyData = Data("invalid legacy journal must be ignored".utf8)

    init() throws {
        paths = AerialPaths(homeDirectory: home, userGeneratedID: "TEST")
        let assetID = UUID().uuidString
        let date = Date(timeIntervalSince1970: 0)
        transaction = TahoeAerialTransactionManifest(
            id: UUID(),
            phase: .restoring,
            createdAt: date,
            registration: TahoeAerialRegistration(
                asset: TahoeAerialAssetRecord(
                    id: assetID,
                    displayName: "Recovery fixture",
                    videoURL: paths.videosDirectory.appending(path: "\(assetID).mov"),
                    thumbnailURL: paths.thumbnailsDirectory.appending(path: "\(assetID).png")
                ),
                videoHash: "already-removed",
                createdAt: date
            ),
            manifestURL: paths.manifest,
            manifestBeforeHash: "unused",
            manifestAfterHash: "unused",
            indexURL: paths.wallpaperIndex,
            indexMutations: []
        )
        journal = paths.tahoeTransactionsDirectory.appending(path: "\(transaction.id.uuidString).json")
        legacyJournal = paths.transactionsDirectory.appending(path: "legacy.json")
        indexData = try PropertyListSerialization.data(
            fromPropertyList: [String: String](), format: .binary, options: 0
        )
        for directory in [paths.tahoeTransactionsDirectory, paths.transactionsDirectory,
                          paths.manifest.deletingLastPathComponent(),
                          paths.wallpaperIndex.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try manifestData.write(to: paths.manifest)
        try indexData.write(to: paths.wallpaperIndex)
        try legacyData.write(to: legacyJournal)
        try AtomicJSONStore(files: LocalFileStore()).write(transaction, to: journal)
    }

    func client(majorVersion: Int) -> ProcessLockScreenSystemClient {
        ProcessLockScreenSystemClient(
            homeDirectory: home,
            generatedUIDProvider: ProcessGeneratedUIDProvider(runCommand: { _ in "GeneratedUID: TEST" }),
            systemVersion: OperatingSystemVersion(majorVersion: majorVersion, minorVersion: 0, patchVersion: 0)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}
