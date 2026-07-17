import Foundation
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class DisplayFeatureStoreTests: XCTestCase {
    @MainActor
    func testUpdateExposesConnectedTargetsAndJoinsMediaAndRuntimeFailure() {
        let media = item("Ocean")
        let online = DisplayRecord(screen: screen("online", name: "Built-in"), connection: .connected)
        let offline = DisplayRecord(record: assignmentRecord("offline", name: "Studio", mediaID: media.id), connection: .disconnected)
        let assignments = DisplayAssignmentSnapshot(records: [assignmentRecord("online", name: "Built-in", mediaID: media.id), assignmentRecord("offline", name: "Studio", mediaID: media.id)], userPaused: true)
        let runtime = RuntimeSnapshot(sessions: [], resourceReferenceCounts: [:], pauseReasons: [.user], failures: [.init(displayID: online.id, mediaID: media.id, message: "failed")], resourceCreationCount: 0)
        let store = DisplayFeatureStore(commands: .noop)

        store.update(catalog: [online, offline], assignments: assignments, media: [media], runtime: runtime)

        XCTAssertEqual(store.assignmentTargets.map(\.id), [online.id])
        XCTAssertEqual(store.cards.map(\.media?.id), [media.id, media.id])
        XCTAssertEqual(store.cards.first?.runtimeError, "failed")
        XCTAssertTrue(store.userPaused)
    }

    @MainActor
    func testCommandFailureIsPublishedWithoutClearingCards() async {
        let online = DisplayRecord(screen: screen("online", name: "Built-in"), connection: .connected)
        let store = DisplayFeatureStore(commands: .init(
            assign: { _, _ in throw CommandError.failed }, remove: { _ in }, clear: { _ in },
            setMode: { _, _ in }, setPaused: { _ in }, retry: { _ in }
        ))
        store.update(catalog: [online], assignments: .empty, media: [], runtime: nil)

        await store.assign(mediaID: UUID(), displayIDs: [online.id])

        XCTAssertEqual(store.cards.map(\.id), [online.id])
        XCTAssertNotNil(store.pageError)
    }
}

private enum CommandError: Error { case failed }
private func screen(_ id: String, name: String) -> DesktopScreen { .init(id: DisplayID("cg-uuid:\(id)"), frame: .zero, name: name, pixelWidth: 1920, pixelHeight: 1080, isMain: false, identityPersistence: .persistent) }
private func assignmentRecord(_ id: String, name: String, mediaID: UUID?) -> PersistedDisplayRecord { .init(displayID: DisplayID("cg-uuid:\(id)"), displayName: name, pixelWidth: 1920, pixelHeight: 1080, wasMain: false, identityPersistence: .persistent, mediaID: mediaID, presentationMode: .fill) }
private func item(_ name: String) -> MediaItem { .init(id: UUID(), sourceHash: "hash", sourceURL: URL(fileURLWithPath: "/source.mov"), displayName: name, sourceByteCount: 1, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30, durationSeconds: 1, codec: "hvc1", variantURL: URL(fileURLWithPath: "/variant.mov"), thumbnailURL: URL(fileURLWithPath: "/thumb.jpg"), coverURL: URL(fileURLWithPath: "/cover.jpg"), createdAt: .distantPast) }
