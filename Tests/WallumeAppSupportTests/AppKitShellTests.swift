import AppKit
import SwiftUI
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class AppKitShellTests: XCTestCase {
    @MainActor
    func testWindowReleasesHostingContentWhenClosed() {
        let controller = MainWindowController { AnyView(Text("Gallery")) }
        controller.show()
        XCTAssertTrue(controller.hasContent)
        controller.closeAndReleaseContent()
        XCTAssertFalse(controller.hasContent)
    }

    func testStatusTitleRepresentsIdleActiveAndFailure() {
        XCTAssertEqual(StatusItemController.title(for: .init(items: [], warnings: [], isActive: false)), "Wallume")
        let running = ImportQueueItem(source: URL(fileURLWithPath: "/a.mov"), attempts: [.init(status: .running)])
        XCTAssertEqual(StatusItemController.title(for: .init(items: [running], warnings: [], isActive: true)), "导入 0/1")
        let failed = ImportQueueItem(source: URL(fileURLWithPath: "/a.mov"), attempts: [.init(status: .failed)])
        XCTAssertEqual(StatusItemController.title(for: .init(items: [failed], warnings: [], isActive: false)), "1 个导入失败")
    }

    func testPanelConfigurationsSeparateFilesAndFolders() {
        XCTAssertTrue(ImportPanelConfiguration.files.allowsMultipleSelection)
        XCTAssertFalse(ImportPanelConfiguration.files.canChooseDirectories)
        XCTAssertTrue(ImportPanelConfiguration.folder.canChooseDirectories)
        XCTAssertFalse(ImportPanelConfiguration.folder.canChooseFiles)
    }

    @MainActor
    func testMediaDetailRendersInHostingView() {
        let item = MediaItem(id: UUID(), sourceHash: "hash", sourceURL: URL(fileURLWithPath: "/tmp/source.mov"), displayName: "Ocean", sourceByteCount: 10, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30, durationSeconds: 5, codec: "hvc1", variantURL: URL(fileURLWithPath: "/tmp/variant.mov"), thumbnailURL: URL(fileURLWithPath: "/tmp/thumb.jpg"), coverURL: URL(fileURLWithPath: "/tmp/cover.jpg"), createdAt: .distantPast)
        let host = NSHostingView(rootView: MediaDetailView(item: item, onReveal: { false }, onDelete: {}))
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}
