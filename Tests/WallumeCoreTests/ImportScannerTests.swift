import Foundation
import XCTest
@testable import WallumeCore

final class ImportScannerTests: XCTestCase {
    func testRecursesWhileIgnoringHiddenAndPackageContentsAndDeduplicating() throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        let root = fixture.root.appending(path: "visible")
        let nested = root.appending(path: "nested")
        let hiddenDirectory = root.appending(path: ".hidden")
        let package = root.appending(path: "Bundle.app")
        try fixture.makeDirectory(nested)
        try fixture.makeDirectory(hiddenDirectory)
        try fixture.makeDirectory(package)
        let movie = nested.appending(path: "Movie.MOV")
        try fixture.makeFile(movie)
        try fixture.makeFile(root.appending(path: ".hidden.mov"))
        try fixture.makeFile(hiddenDirectory.appending(path: "ignored.mp4"))
        try fixture.makeFile(package.appending(path: "inside.mov"))
        try fixture.makeFile(root.appending(path: "note.txt"))

        let result = LocalImportScanner().scan([root, movie])

        XCTAssertEqual(result.candidates, [movie.standardizedFileURL])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testUnreadableInputBecomesWarningAndOtherInputsContinue() throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        let movie = fixture.root.appending(path: "good.mp4")
        try fixture.makeFile(movie)
        let missing = fixture.root.appending(path: "missing")

        let result = LocalImportScanner().scan([missing, movie])

        XCTAssertEqual(result.candidates, [movie.standardizedFileURL])
        XCTAssertEqual(result.warnings.map(\.url), [missing.standardizedFileURL])
    }

    func testCandidatesUseStableLocalizedPathOrder() throws {
        let fixture = try ScannerFixture()
        defer { fixture.remove() }
        let b = fixture.root.appending(path: "b.mov")
        let a = fixture.root.appending(path: "a.mp4")
        try fixture.makeFile(b)
        try fixture.makeFile(a)

        let result = LocalImportScanner().scan([b, a])

        XCTAssertEqual(result.candidates, [a.standardizedFileURL, b.standardizedFileURL])
    }
}

private final class ScannerFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "Wallume-ImportScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func makeFile(_ url: URL) throws {
        try Data("media".utf8).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
