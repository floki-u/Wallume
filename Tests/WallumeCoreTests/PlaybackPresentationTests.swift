import Foundation
import XCTest
@testable import WallumeCore

final class PlaybackPresentationTests: XCTestCase {
    @MainActor
    func testSurfaceReceivesOpaquePresentationAndFallback() {
        let surface = RecordingPresentationSurface()
        let presentation = PlaybackPresentation(resourceID: UUID())
        let fallback = URL(fileURLWithPath: "/tmp/cover.jpg")

        surface.setPresentation(presentation, fallbackURL: fallback)

        XCTAssertEqual(surface.presentation, presentation)
        XCTAssertEqual(surface.fallbackURL, fallback)
    }
}

@MainActor
private final class RecordingPresentationSurface: DesktopSurface {
    var presentation: PlaybackPresentation?
    var fallbackURL: URL?

    func show(frame: CGRect) {}
    func setPresentation(_ presentation: PlaybackPresentation?, fallbackURL: URL?) {
        self.presentation = presentation
        self.fallbackURL = fallbackURL
    }
    func close() {}
}
