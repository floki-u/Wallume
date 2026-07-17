import Foundation
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class LockScreenFeatureStoreTests: XCTestCase {
    @MainActor
    func testStoreMirrorsServiceSnapshotsAndDispatchesCommands() async throws {
        let fixture = try LockScreenFeatureStoreFixture()
        defer { fixture.cleanup() }
        let recorder = FeatureCommandRecorder()
        let store = LockScreenFeatureStore(
            service: fixture.service,
            commands: .init(
                refreshProbe: { await recorder.append("refresh") },
                selectAerialSlot: { await recorder.append("select:\($0)") },
                confirmEnable: { await recorder.append("confirm") },
                disableAndRestore: { await recorder.append("restore") },
                retry: { await recorder.append("retry") }
            )
        )

        await fixture.service.start()
        await fixture.service.waitForIdle()
        await eventually { store.state.phase == .readyToConfigure }
        XCTAssertEqual(store.state.probe?.availableSlots.map(\.id), [fixture.aerialID])

        await store.refreshProbe()
        await store.selectAerialSlot(fixture.aerialID)
        await store.confirmEnable()
        await store.disableAndRestore()
        await store.retry()

        let commands = await recorder.commands
        XCTAssertEqual(commands, ["refresh", "select:\(fixture.aerialID)", "confirm", "restore", "retry"])
    }

    @MainActor
    func testCommandErrorSurvivesUnrelatedNonErrorServiceSnapshots() async throws {
        let fixture = try LockScreenFeatureStoreFixture()
        defer { fixture.cleanup() }
        let commands = LockScreenFeatureCommands(
            refreshProbe: { throw FeatureCommandError.failed },
            selectAerialSlot: { _ in },
            confirmEnable: {},
            disableAndRestore: {},
            retry: {}
        )
        let store = LockScreenFeatureStore(service: fixture.service, commands: commands)

        await store.refreshProbe()
        XCTAssertEqual(store.pageError, "操作失败")

        await fixture.service.start()
        await fixture.service.waitForIdle()
        await eventually { store.state.phase == .readyToConfigure }
        XCTAssertEqual(store.pageError, "操作失败")
    }

    @MainActor
    func testStoreDeinitializationDoesNotStopService() async throws {
        let fixture = try LockScreenFeatureStoreFixture()
        defer { fixture.cleanup() }
        weak var weakStore: LockScreenFeatureStore?

        do {
            let store = LockScreenFeatureStore(service: fixture.service)
            weakStore = store
        }
        XCTAssertNil(weakStore)

        await fixture.service.start()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.probeCallCount, 1)
        let snapshot = await fixture.service.snapshot()
        XCTAssertEqual(snapshot.phase, .readyToConfigure)
    }
}

private enum FeatureCommandError: LocalizedError {
    case failed
    var errorDescription: String? { "操作失败" }
}

private actor FeatureCommandRecorder {
    private(set) var commands = [String]()
    func append(_ command: String) { commands.append(command) }
}

@MainActor
private func eventually(
    timeout: TimeInterval = 1,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition())
}

final class LockScreenFeatureStoreFixture {
    let aerialID = "com.apple.aerials.sea"
    let root: URL
    let service: LockScreenSyncService
    let client: FeatureStoreSystemClient

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        client = FeatureStoreSystemClient(aerialID: aerialID)
        let files = LocalFileStore()
        let configurationURL = root.appendingPathComponent("lock-screen.json")
        let configurationStore = LockScreenConfigurationStore(
            url: configurationURL,
            files: files,
            jsonStore: AtomicJSONStore(files: files)
        )
        service = LockScreenSyncService(
            configurationStore: configurationStore,
            systemClient: client,
            files: files
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

final class FeatureStoreSystemClient: LockScreenSystemClient, @unchecked Sendable {
    private let lock = NSLock()
    private let aerialID: String
    private var probeCalls = 0

    init(aerialID: String) { self.aerialID = aerialID }

    var probeCallCount: Int { lock.withLock { probeCalls } }

    func probe() throws -> LockScreenProbeReport {
        lock.withLock { probeCalls += 1 }
        return .init(
            generation: .sequoia,
            writesPermitted: true,
            manifestExists: true,
            indexExists: true,
            availableSlots: [.init(id: aerialID, displayName: "海岸", videoURL: URL(fileURLWithPath: "/fixture.mov"))],
            foreignBackupNames: []
        )
    }

    func install(media: MediaItem, aerialID: String) throws -> LockScreenTransactionManifest {
        throw FeatureCommandError.failed
    }

    func inspectRecovery() throws -> [RecoveryCandidate] { [] }
    func restore(transactionID: UUID) throws -> RecoveryReport { .init(restored: [], conflicts: [], retainedBackups: []) }
}
