import Foundation
import XCTest
@testable import WallumeCore

final class MediaCommandTests: XCTestCase {
    func testImportPrintsOrderedPerFileResultsAndReturnsOneForPartialFailure() async {
        let fixture = MediaCommandFixture()
        let imported = MediaItem.fixture(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "a"
        )
        fixture.importer.report = MediaImportReport(results: [
            MediaImportResult(source: URL(fileURLWithPath: "/input/a.mov"), status: .imported, item: imported),
            MediaImportResult(
                source: URL(fileURLWithPath: "/input/b.mov"),
                status: .failed,
                message: "unreadable"
            ),
        ])

        let code = await fixture.command.run(arguments: ["import", "/input"])

        XCTAssertEqual(code, 1)
        XCTAssertEqual(
            fixture.output.stdout,
            """
            imported a.mov 00000000-0000-0000-0000-000000000001
            failed b.mov unreadable

            """
        )
        XCTAssertEqual(fixture.importer.importedURLs, [URL(fileURLWithPath: "/input")])
    }

    func testListAndShowAreReadOnly() async {
        let fixture = MediaCommandFixture()
        let item = MediaItem.fixture(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            displayName: "Ocean"
        )
        fixture.library.items = [item]

        let listCode = await fixture.command.run(arguments: ["list"])
        let showCode = await fixture.command.run(arguments: ["show", item.id.uuidString])

        XCTAssertEqual(listCode, 0)
        XCTAssertEqual(showCode, 0)

        XCTAssertEqual(fixture.library.removeCalls, [])
        XCTAssertEqual(fixture.output.stderr, "")
        XCTAssertTrue(fixture.output.stdout.contains("00000000-0000-0000-0000-000000000002 Ocean"))
        XCTAssertTrue(fixture.output.stdout.contains("displayName: Ocean"))
    }

    func testRemoveRejectsMalformedUUIDWithoutCallingLibrary() async {
        let fixture = MediaCommandFixture()

        let code = await fixture.command.run(arguments: ["remove", "not-a-uuid"])

        XCTAssertEqual(code, 64)

        XCTAssertEqual(fixture.library.removeCalls, [])
        XCTAssertEqual(
            fixture.output.stderr,
            "usage: wallume-media import <path>... | list | show <media-id> | remove <media-id>\n"
        )
    }

    func testRemoveDeletesItemByID() async {
        let fixture = MediaCommandFixture()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        let code = await fixture.command.run(arguments: ["remove", id.uuidString])

        XCTAssertEqual(code, 0)

        XCTAssertEqual(fixture.library.removeCalls, [id])
        XCTAssertEqual(fixture.output.stdout, "removed 00000000-0000-0000-0000-000000000003\n")
    }
}

private final class MediaCommandFixture {
    let importer = StubMediaImporter()
    let library = StubMediaLibrary()
    let output = BufferedMediaOutput()
    lazy var command = MediaCommand(importer: importer, library: library, output: output)
}

private final class StubMediaImporter: MediaImportingService, @unchecked Sendable {
    var report = MediaImportReport(results: [])
    private(set) var importedURLs: [URL] = []

    func importURLs(_ urls: [URL]) async throws -> MediaImportReport {
        importedURLs = urls
        return report
    }
}

private final class StubMediaLibrary: MediaLibraryManaging, @unchecked Sendable {
    var items: [MediaItem] = []
    private(set) var removeCalls: [UUID] = []

    func list() throws -> [MediaItem] {
        items
    }

    func item(id: UUID) throws -> MediaItem? {
        items.first { $0.id == id }
    }

    func remove(id: UUID) throws {
        removeCalls.append(id)
    }
}

private final class BufferedMediaOutput: MediaCommandOutput {
    private(set) var stdout = ""
    private(set) var stderr = ""

    func writeStdout(_ text: String) {
        stdout += text
    }

    func writeStderr(_ text: String) {
        stderr += text
    }
}

private extension MediaItem {
    static func fixture(id: UUID, displayName: String) -> MediaItem {
        MediaItem(
            id: id,
            sourceHash: String(repeating: "a", count: 64),
            sourceURL: URL(fileURLWithPath: "/input/\(displayName).mov"),
            displayName: displayName,
            sourceByteCount: 42,
            pixelWidth: 1920,
            pixelHeight: 1080,
            frameRate: 30,
            durationSeconds: 5,
            codec: "hvc1",
            variantURL: URL(fileURLWithPath: "/library/\(id.uuidString).mov"),
            thumbnailURL: URL(fileURLWithPath: "/cache/\(id.uuidString).jpg"),
            coverURL: URL(fileURLWithPath: "/cache/\(id.uuidString)-cover.jpg"),
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
