import XCTest
@testable import WallumeAppSupport

final class ApplicationCompositionTests: XCTestCase {
    func testTerminationPolicyOnlyPromptsForActiveQueue() {
        XCTAssertEqual(TerminationPolicy.decision(queueActive: false), .terminateNow)
        XCTAssertEqual(TerminationPolicy.decision(queueActive: true), .requestConfirmation)
    }
}
