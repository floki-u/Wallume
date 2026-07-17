import Foundation
import XCTest
@testable import WallumeCore

final class PlaybackPresentationTests: XCTestCase {
    @MainActor
    func testSurfaceReceivesOpaquePresentationAndFallback() {
        let surface = RecordingPresentationSurface()
        let presentation = PlaybackPresentation(resourceID: UUID())
        let fallback = URL(fileURLWithPath: "/tmp/cover.jpg")

        try? surface.setPresentation(presentation, fallbackURL: fallback, mode: .fill)

        XCTAssertEqual(surface.presentation, presentation)
        XCTAssertEqual(surface.fallbackURL, fallback)
    }
}

@MainActor
private final class RecordingPresentationSurface: DesktopSurface {
    var presentation: PlaybackPresentation?
    var fallbackURL: URL?

    func show(frame: CGRect) {}
    func setPresentation(_ presentation: PlaybackPresentation?, fallbackURL: URL?, mode: WallpaperPresentationMode) throws {
        self.presentation = presentation
        self.fallbackURL = fallbackURL
    }
    func close() {}
}
