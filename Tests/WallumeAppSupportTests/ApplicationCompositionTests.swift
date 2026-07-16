import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class ApplicationCompositionTests: XCTestCase {
    func testTerminationPolicyOnlyPromptsForActiveQueue() {
        XCTAssertEqual(TerminationPolicy.decision(queueActive: false), .terminateNow)
        XCTAssertEqual(TerminationPolicy.decision(queueActive: true), .requestConfirmation)
    }

    func testImmediatePostEnqueueTerminationDecisionUsesAuthoritativeQueue() async {
        let importer = CompositionImporter()
        let queue = ImportQueue(importer: importer, scanner: CompositionScanner())
        await queue.enqueue([URL(fileURLWithPath: "/a.mov")])
        let decision = await TerminationPolicy.decision(queue: queue)
        XCTAssertEqual(decision, .requestConfirmation)
        await queue.cancelAllAndWait()
    }
}

private struct CompositionScanner: ImportScanning {
    func scan(_ urls: [URL]) -> ImportScanResult { .init(candidates: urls, warnings: []) }
}
private struct CompositionImporter: SingleMediaImporting {
    func importURL(_ source: URL, onEvent: @escaping @Sendable (MediaImportEvent) -> Void) async -> MediaImportResult {
        while !Task.isCancelled { await Task.yield() }
        return .init(source: source, status: .cancelled)
    }
}
