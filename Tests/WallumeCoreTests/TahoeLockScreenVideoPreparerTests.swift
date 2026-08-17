import Foundation
import XCTest
@testable import WallumeCore

final class TahoeLockScreenVideoPreparerTests: XCTestCase {
    /// Hardware/OS integration coverage. CI skips this unless supplied with a local Tahoe-capable
    /// media fixture; it keeps the exact production encoder path runnable against a real decoder.
    func testPreparesExactTahoeProfileFromConfiguredFixture() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["WALLUME_TAHOE_TEST_SOURCE"],
              !sourcePath.isEmpty else {
            throw XCTSkip("Set WALLUME_TAHOE_TEST_SOURCE to run the Tahoe hardware integration test")
        }
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wallume-tahoe-test-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: destination) }

        let preparer = TahoeLockScreenVideoPreparer()
        try await preparer.prepare(source: URL(fileURLWithPath: sourcePath), destination: destination)

        let isCompatible = try await preparer.isCompatible(destination)
        XCTAssertTrue(isCompatible)
    }
}
