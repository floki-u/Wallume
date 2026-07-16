import XCTest
@testable import WallumeCore

final class RuntimeBenchmarkTests: XCTestCase {
    func testLaunchParserAcceptsNormalAndStrictBenchmarkForms() throws {
        let id = UUID()
        let normal = try XCTUnwrap(RuntimeLaunchConfiguration.parse([id.uuidString]))
        XCTAssertEqual(normal.mediaID, id)
        XCTAssertNil(normal.benchmark)

        let benchmark = try XCTUnwrap(RuntimeLaunchConfiguration.parse([
            "benchmark", id.uuidString, "--duration", "300", "--scenario", "dual-shared",
        ]))
        XCTAssertEqual(benchmark.mediaID, id)
        XCTAssertEqual(benchmark.benchmark?.duration, 300)
        XCTAssertEqual(benchmark.benchmark?.scenario, .dualShared)
    }

    func testLaunchParserRejectsInvalidBenchmarkBoundariesAndShape() {
        let id = UUID().uuidString
        XCTAssertNil(RuntimeLaunchConfiguration.parse(["benchmark", id, "--duration", "4", "--scenario", "paused"]))
        XCTAssertNil(RuntimeLaunchConfiguration.parse(["benchmark", id, "--duration", "3601", "--scenario", "paused"]))
        XCTAssertNil(RuntimeLaunchConfiguration.parse(["benchmark", id, "--scenario", "paused", "--duration", "30"]))
        XCTAssertNil(RuntimeLaunchConfiguration.parse(["benchmark", id, "--duration", "30", "--scenario", "unknown"]))
    }

    func testReportAggregatesSamplesAndEncodesHardwareBlock() throws {
        let report = RuntimeBenchmarkReport(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            scenario: .single1080p,
            hardwareModel: "Mac14,2",
            operatingSystem: "macOS 14.7",
            displayCount: 1,
            mediaWidth: 1920,
            mediaHeight: 1080,
            mediaFramesPerSecond: 30,
            samples: [
                RuntimeMetricSample(residentBytes: 80, cpuPercent: 2),
                RuntimeMetricSample(residentBytes: 120, cpuPercent: 6),
            ],
            pauseReasons: [],
            sharedResourceCount: 1,
            gpuStatus: .notMeasured
        )

        XCTAssertEqual(report.averageResidentBytes, 100)
        XCTAssertEqual(report.peakResidentBytes, 120)
        XCTAssertEqual(report.averageCPUPercent, 4)
        XCTAssertEqual(report.peakCPUPercent, 6)
        XCTAssertEqual(report.certification, .blockedByHardware)
        XCTAssertTrue(report.developmentOnly)

        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["certification"] as? String, "blockedByHardware")
        XCTAssertEqual(object["sampleCount"] as? Int, 2)
    }

    func testEmptyReportHasZeroAggregates() {
        let report = RuntimeBenchmarkReport(
            timestamp: Date(timeIntervalSince1970: 0),
            scenario: .paused,
            hardwareModel: "unknown",
            operatingSystem: "unknown",
            displayCount: 0,
            mediaWidth: nil,
            mediaHeight: nil,
            mediaFramesPerSecond: nil,
            samples: [],
            pauseReasons: [.user],
            sharedResourceCount: 0,
            gpuStatus: .notMeasured
        )

        XCTAssertEqual(report.averageResidentBytes, 0)
        XCTAssertEqual(report.peakResidentBytes, 0)
        XCTAssertEqual(report.averageCPUPercent, 0)
        XCTAssertEqual(report.peakCPUPercent, 0)
    }
}
