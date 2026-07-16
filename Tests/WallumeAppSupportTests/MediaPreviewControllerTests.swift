import XCTest
@testable import WallumeAppSupport

final class MediaPreviewControllerTests: XCTestCase {
    @MainActor
    func testPreviewIsMutedAndReleasedOnClose() {
        let player = PreviewPlayerSpy()
        let controller = MediaPreviewController(factory: { _ in player })

        controller.play(URL(fileURLWithPath: "/tmp/video.mov"))
        XCTAssertEqual(player.volume, 0)
        XCTAssertEqual(player.playCalls, 1)

        controller.releasePlayer()
        XCTAssertEqual(player.pauseCalls, 1)
        XCTAssertNil(controller.player)
    }
}

private final class PreviewPlayerSpy: MediaPreviewPlaying {
    var volume: Float = 1
    var playCalls = 0
    var pauseCalls = 0
    func play() { playCalls += 1 }
    func pause() { pauseCalls += 1 }
}
