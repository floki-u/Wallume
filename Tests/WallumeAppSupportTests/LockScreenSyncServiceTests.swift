import Foundation
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class LockScreenSyncServiceTests: XCTestCase {
    func testFakeSystemClientRecordsCallsWithoutFilesystemPathsOrProcessExecution() throws {
        let probe = LockScreenProbeReport(
            generation: .sequoia,
            writesPermitted: true,
            manifestExists: true,
            indexExists: true,
            availableSlots: [],
            foreignBackupNames: []
        )
        let manifest = makeManifest()
        let candidate = RecoveryCandidate(
            id: manifest.id,
            phase: .committed,
            aerialID: manifest.aerialID,
            createdAt: manifest.createdAt
        )
        let report = RecoveryReport(
            restored: [URL(string: "https://example.test/restored")!],
            conflicts: [],
            retainedBackups: []
        )
        let media = makeMedia()
        let client = FakeLockScreenSystemClient(
            probeResult: .success(probe),
            installResult: .success(manifest),
            recoveryResult: .success([candidate]),
            restoreResult: .success(report)
        )

        XCTAssertEqual(try client.probe(), probe)
        XCTAssertEqual(try client.install(media: media, aerialID: "com.apple.aerials.sea"), manifest)
        XCTAssertEqual(try client.inspectRecovery(), [candidate])
        XCTAssertEqual(try client.restore(transactionID: manifest.id), report)
        XCTAssertEqual(
            client.calls,
            [
                .probe,
                .install(mediaID: media.id, aerialID: "com.apple.aerials.sea"),
                .inspectRecovery,
                .restore(transactionID: manifest.id),
            ]
        )
    }

    func testFakeSystemClientCanThrowAtEveryClientOperation() {
        let media = makeMedia()
        let transactionID = UUID()
        let error = FakeClientError.expected
        let client = FakeLockScreenSystemClient(
            probeResult: .failure(error),
            installResult: .failure(error),
            recoveryResult: .failure(error),
            restoreResult: .failure(error)
        )

        assertThrowsExpectedError { _ = try client.probe() }
        assertThrowsExpectedError { _ = try client.install(media: media, aerialID: "com.apple.aerials.sea") }
        assertThrowsExpectedError { _ = try client.inspectRecovery() }
        assertThrowsExpectedError { _ = try client.restore(transactionID: transactionID) }
    }

    func testProductionClientMapsMediaVariantAndCoverToTransactionRequest() {
        let media = makeMedia()
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 1)

        let request = ProcessLockScreenSystemClient.transactionRequest(
            media: media,
            aerialID: "com.apple.aerials.sea",
            systemVersion: version
        )

        XCTAssertEqual(request.systemVersion.majorVersion, version.majorVersion)
        XCTAssertEqual(request.systemVersion.minorVersion, version.minorVersion)
        XCTAssertEqual(request.systemVersion.patchVersion, version.patchVersion)
        XCTAssertEqual(request.aerialID, "com.apple.aerials.sea")
        XCTAssertEqual(request.optimizedVideo, media.variantURL)
        XCTAssertEqual(request.poster, media.coverURL)
    }

    func testGeneratedUIDProviderParsesDSCLOutputWithoutRunningProcess() throws {
        let homeDirectory = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let provider = ProcessGeneratedUIDProvider { homeDirectory in
            XCTAssertEqual(homeDirectory, URL(fileURLWithPath: "/Users/test", isDirectory: true))
            return "GeneratedUID: USER-UUID\nPrimaryGroupID: 20\n"
        }

        let generatedUID = try provider.generatedUID(for: homeDirectory)

        XCTAssertEqual(generatedUID, "USER-UUID")
    }

    func testGeneratedUIDProviderSurfacesTypedPathCommandAndParseFailures() {
        let malformedProvider = ProcessGeneratedUIDProvider { _ in "PrimaryGroupID: 20\n" }
        let commandFailureProvider = ProcessGeneratedUIDProvider { _ in throw FakeClientError.expected }
        let homeDirectory = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        XCTAssertThrowsError(try malformedProvider.generatedUID(for: homeDirectory)) { error in
            XCTAssertEqual(error as? GeneratedUIDProviderError, .malformedOutput)
        }
        XCTAssertThrowsError(try commandFailureProvider.generatedUID(for: homeDirectory)) { error in
            XCTAssertEqual(error as? GeneratedUIDProviderError, .commandFailed)
        }
        XCTAssertThrowsError(try malformedProvider.generatedUID(for: URL(string: "https://example.test/home")!)) { error in
            XCTAssertEqual(
                error as? GeneratedUIDProviderError,
                .invalidHomeDirectory(URL(string: "https://example.test/home")!)
            )
        }
    }

    func testProductionClientSurfacesGeneratedUIDFailureBeforeInstall() {
        let homeDirectory = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let client = ProcessLockScreenSystemClient(
            homeDirectory: homeDirectory,
            generatedUIDProvider: ThrowingGeneratedUIDProvider(),
            systemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )

        XCTAssertThrowsError(try client.install(media: makeMedia(), aerialID: "com.apple.aerials.sea")) { error in
            XCTAssertEqual(error as? LockScreenSystemClientError, .generatedUID(.commandFailed))
        }
    }

    func testProductionClientSkipsGeneratedUIDLookupWhenNoRecoveryTransactionsExist() throws {
        let provider = RecordingGeneratedUIDProvider()
        let homeDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let client = ProcessLockScreenSystemClient(
            homeDirectory: homeDirectory,
            generatedUIDProvider: provider,
            systemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )

        XCTAssertEqual(try client.inspectRecovery(), [])
        XCTAssertEqual(provider.callCount, 0)
    }

    private func assertThrowsExpectedError(_ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? FakeClientError, .expected)
        }
    }
}

private final class FakeLockScreenSystemClient: LockScreenSystemClient, @unchecked Sendable {
    enum Call: Equatable {
        case probe
        case install(mediaID: UUID, aerialID: String)
        case inspectRecovery
        case restore(transactionID: UUID)
    }

    private let probeResult: Result<LockScreenProbeReport, FakeClientError>
    private let installResult: Result<LockScreenTransactionManifest, FakeClientError>
    private let recoveryResult: Result<[RecoveryCandidate], FakeClientError>
    private let restoreResult: Result<RecoveryReport, FakeClientError>
    private(set) var calls: [Call] = []

    init(
        probeResult: Result<LockScreenProbeReport, FakeClientError>,
        installResult: Result<LockScreenTransactionManifest, FakeClientError>,
        recoveryResult: Result<[RecoveryCandidate], FakeClientError>,
        restoreResult: Result<RecoveryReport, FakeClientError>
    ) {
        self.probeResult = probeResult
        self.installResult = installResult
        self.recoveryResult = recoveryResult
        self.restoreResult = restoreResult
    }

    func probe() throws -> LockScreenProbeReport {
        calls.append(.probe)
        return try probeResult.get()
    }

    func install(media: MediaItem, aerialID: String) throws -> LockScreenTransactionManifest {
        calls.append(.install(mediaID: media.id, aerialID: aerialID))
        return try installResult.get()
    }

    func inspectRecovery() throws -> [RecoveryCandidate] {
        calls.append(.inspectRecovery)
        return try recoveryResult.get()
    }

    func restore(transactionID: UUID) throws -> RecoveryReport {
        calls.append(.restore(transactionID: transactionID))
        return try restoreResult.get()
    }
}

private struct ThrowingGeneratedUIDProvider: GeneratedUIDProviding {
    func generatedUID(for homeDirectory: URL) throws -> String {
        throw GeneratedUIDProviderError.commandFailed
    }
}

private final class RecordingGeneratedUIDProvider: GeneratedUIDProviding, @unchecked Sendable {
    private(set) var callCount = 0

    func generatedUID(for homeDirectory: URL) throws -> String {
        callCount += 1
        return "USER-UUID"
    }
}

private enum FakeClientError: Error, Equatable {
    case expected
}

private func makeMedia() -> MediaItem {
    MediaItem(
        id: UUID(uuidString: "3B3F872A-79E0-4BB7-9F3B-9E91794728CF")!,
        sourceHash: "source-hash",
        sourceURL: URL(string: "https://example.test/source")!,
        displayName: "Example",
        sourceByteCount: 1,
        pixelWidth: 1,
        pixelHeight: 1,
        frameRate: 30,
        durationSeconds: 1,
        codec: "h264",
        variantURL: URL(string: "https://example.test/variant")!,
        thumbnailURL: URL(string: "https://example.test/thumbnail")!,
        coverURL: URL(string: "https://example.test/cover")!,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeManifest() -> LockScreenTransactionManifest {
    LockScreenTransactionManifest(
        schemaVersion: 2,
        id: UUID(uuidString: "22F12AB3-7C94-44B7-91CD-62B1ED4A4E51")!,
        phase: .committed,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        osMajorVersion: 15,
        aerialID: "com.apple.aerials.sea",
        video: FileReplacementRecord(
            target: URL(string: "https://example.test/video")!,
            originalHash: "original-video",
            installedHash: "installed-video",
            originalBackup: URL(string: "https://example.test/video.backup")!
        ),
        poster: FileReplacementRecord(
            target: URL(string: "https://example.test/poster")!,
            originalHash: "original-poster",
            installedHash: "installed-poster",
            originalBackup: URL(string: "https://example.test/poster.backup")!
        ),
        indexURL: URL(string: "https://example.test/index")!,
        indexMutations: [],
        primaryBackup: URL(string: "https://example.test/primary.backup")!,
        recoveryBackup: URL(string: "https://example.test/recovery.backup")!
    )
}
