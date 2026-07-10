import XCTest
@testable import WallumeCore

private struct JournalFixture: Codable, Equatable, Sendable {
    let phase: String
    let count: Int
}

final class AtomicIOTests: XCTestCase {
    func testAtomicJSONRoundTripLeavesNoTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let target = root.appending(path: "journal.json")
        let files = LocalFileStore()
        let store = AtomicJSONStore(files: files)

        try store.write(JournalFixture(phase: "prepared", count: 2), to: target)

        XCTAssertEqual(
            try store.read(JournalFixture.self, from: target),
            .init(phase: "prepared", count: 2)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".tmp"))
    }

    func testSHA256UsesLowercaseHex() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "value")
        try Data("wallume".utf8).write(to: file)

        XCTAssertEqual(
            try SHA256Digester().sha256(of: file),
            "66c0fb338a923a6b5af567f8489078f61fc52d070a952d6aa602b484a5c31e60"
        )
    }
}
