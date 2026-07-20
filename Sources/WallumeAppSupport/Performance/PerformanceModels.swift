import Foundation
import WallumeCore

public struct PerformanceSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let cpuPercent: Double
    public let residentBytes: UInt64

    public init(timestamp: Date, cpuPercent: Double, residentBytes: UInt64) {
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
    }
}

/// A privacy-safe count-only snapshot of the active wallpaper runtime.
public struct PerformanceRuntimeContext: Codable, Equatable, Sendable {
    public let activeDisplayCount: Int
    public let activeSessionCount: Int
    public let activeResourceCount: Int
    public let sharedResourceCount: Int
    public let sharedResourceReferenceCount: Int
    public let resourceCreationCount: Int
    public let pauseReasons: [RuntimePauseReason]

    public init(
        activeDisplayCount: Int,
        activeSessionCount: Int,
        activeResourceCount: Int,
        sharedResourceCount: Int,
        sharedResourceReferenceCount: Int,
        resourceCreationCount: Int,
        pauseReasons: [RuntimePauseReason]
    ) {
        self.activeDisplayCount = activeDisplayCount
        self.activeSessionCount = activeSessionCount
        self.activeResourceCount = activeResourceCount
        self.sharedResourceCount = sharedResourceCount
        self.sharedResourceReferenceCount = sharedResourceReferenceCount
        self.resourceCreationCount = resourceCreationCount
        self.pauseReasons = pauseReasons.sorted { $0.rawValue < $1.rawValue }
    }

    public init(snapshot: WallpaperRuntimeSnapshot) {
        let runtime = snapshot.runtime
        let sharedReferenceCounts = runtime.resourceReferenceCounts.values.filter { $0 > 1 }
        self.init(
            activeDisplayCount: snapshot.activeDisplayCount,
            activeSessionCount: runtime.sessions.count,
            activeResourceCount: runtime.resourceReferenceCounts.count,
            sharedResourceCount: sharedReferenceCounts.count,
            sharedResourceReferenceCount: sharedReferenceCounts.reduce(0, +),
            resourceCreationCount: runtime.resourceCreationCount,
            pauseReasons: Array(runtime.pauseReasons)
        )
    }
}

public struct PerformanceSummary: Equatable, Sendable {
    public static let maximumSampleCount = 60

    public let samples: [PerformanceSample]
    public let currentCPUPercent: Double
    public let averageCPUPercent: Double
    public let peakCPUPercent: Double
    public let currentResidentBytes: UInt64
    public let averageResidentBytes: UInt64
    public let peakResidentBytes: UInt64

    public init(samples: [PerformanceSample]) {
        self.samples = Array(samples.suffix(Self.maximumSampleCount))
        guard let current = self.samples.last else {
            currentCPUPercent = 0
            averageCPUPercent = 0
            peakCPUPercent = 0
            currentResidentBytes = 0
            averageResidentBytes = 0
            peakResidentBytes = 0
            return
        }

        currentCPUPercent = current.cpuPercent
        currentResidentBytes = current.residentBytes
        averageCPUPercent = self.samples.map(\.cpuPercent).reduce(0, +) / Double(self.samples.count)
        peakCPUPercent = self.samples.map(\.cpuPercent).max() ?? 0
        averageResidentBytes = self.samples.map(\.residentBytes).reduce(0, +) / UInt64(self.samples.count)
        peakResidentBytes = self.samples.map(\.residentBytes).max() ?? 0
    }

    public func appending(_ sample: PerformanceSample) -> PerformanceSummary {
        PerformanceSummary(samples: samples + [sample])
    }
}

public enum PerformanceDiagnosticReportError: Error, Equatable {
    case unsupportedSchema(Int)
    case unexpectedFields(Set<String>)
    case sensitiveFieldValue(String)
}

/// The persistent diagnostic document. It intentionally contains aggregate and count-only data.
public struct PerformanceDiagnosticReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let startedAt: Date
    public let duration: TimeInterval
    public let sampleCount: Int
    public let scenario: String
    public let averageCPUPercent: Double
    public let peakCPUPercent: Double
    public let averageResidentBytes: UInt64
    public let peakResidentBytes: UInt64
    public let activeDisplayCount: Int
    public let activeSessionCount: Int
    public let activeResourceCount: Int
    public let sharedResourceCount: Int
    public let sharedResourceReferenceCount: Int
    public let resourceCreationCount: Int
    public let pauseReasons: [RuntimePauseReason]
    public let chip: String
    public let physicalMemoryBytes: UInt64
    public let macOSVersion: String

    public init(
        startedAt: Date,
        duration: TimeInterval,
        scenario: String,
        summary: PerformanceSummary,
        runtime: PerformanceRuntimeContext,
        chip: String,
        physicalMemoryBytes: UInt64,
        macOSVersion: String
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.startedAt = startedAt
        self.duration = duration
        sampleCount = summary.samples.count
        self.scenario = scenario
        averageCPUPercent = summary.averageCPUPercent
        peakCPUPercent = summary.peakCPUPercent
        averageResidentBytes = summary.averageResidentBytes
        peakResidentBytes = summary.peakResidentBytes
        activeDisplayCount = runtime.activeDisplayCount
        activeSessionCount = runtime.activeSessionCount
        activeResourceCount = runtime.activeResourceCount
        sharedResourceCount = runtime.sharedResourceCount
        sharedResourceReferenceCount = runtime.sharedResourceReferenceCount
        resourceCreationCount = runtime.resourceCreationCount
        pauseReasons = runtime.pauseReasons
        self.chip = chip
        self.physicalMemoryBytes = physicalMemoryBytes
        self.macOSVersion = macOSVersion
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case startedAt
        case duration
        case sampleCount
        case scenario
        case averageCPUPercent
        case peakCPUPercent
        case averageResidentBytes
        case peakResidentBytes
        case activeDisplayCount
        case activeSessionCount
        case activeResourceCount
        case sharedResourceCount
        case sharedResourceReferenceCount
        case resourceCreationCount
        case pauseReasons
        case chip
        case physicalMemoryBytes
        case macOSVersion
    }

    public init(from decoder: any Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyCodingKey.self)
        let expectedFields = Set(CodingKeys.allCases.map(\.rawValue))
        let unexpectedFields = Set(allFields.allKeys.map(\.stringValue)).subtracting(expectedFields)
        guard unexpectedFields.isEmpty else {
            throw PerformanceDiagnosticReportError.unexpectedFields(unexpectedFields)
        }

        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        guard decodedSchemaVersion == Self.currentSchemaVersion else {
            throw PerformanceDiagnosticReportError.unsupportedSchema(decodedSchemaVersion)
        }

        schemaVersion = decodedSchemaVersion
        startedAt = try fields.decode(Date.self, forKey: .startedAt)
        duration = try fields.decode(TimeInterval.self, forKey: .duration)
        sampleCount = try fields.decode(Int.self, forKey: .sampleCount)
        scenario = try fields.decode(String.self, forKey: .scenario)
        averageCPUPercent = try fields.decode(Double.self, forKey: .averageCPUPercent)
        peakCPUPercent = try fields.decode(Double.self, forKey: .peakCPUPercent)
        averageResidentBytes = try fields.decode(UInt64.self, forKey: .averageResidentBytes)
        peakResidentBytes = try fields.decode(UInt64.self, forKey: .peakResidentBytes)
        activeDisplayCount = try fields.decode(Int.self, forKey: .activeDisplayCount)
        activeSessionCount = try fields.decode(Int.self, forKey: .activeSessionCount)
        activeResourceCount = try fields.decode(Int.self, forKey: .activeResourceCount)
        sharedResourceCount = try fields.decode(Int.self, forKey: .sharedResourceCount)
        sharedResourceReferenceCount = try fields.decode(Int.self, forKey: .sharedResourceReferenceCount)
        resourceCreationCount = try fields.decode(Int.self, forKey: .resourceCreationCount)
        pauseReasons = try fields.decode([RuntimePauseReason].self, forKey: .pauseReasons)
        chip = try fields.decode(String.self, forKey: .chip)
        physicalMemoryBytes = try fields.decode(UInt64.self, forKey: .physicalMemoryBytes)
        macOSVersion = try fields.decode(String.self, forKey: .macOSVersion)
        try Self.validateRedactedStrings(
            scenario: scenario,
            chip: chip,
            macOSVersion: macOSVersion
        )
    }

    public func encode(to encoder: any Encoder) throws {
        try Self.validateRedactedStrings(
            scenario: scenario,
            chip: chip,
            macOSVersion: macOSVersion
        )

        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(schemaVersion, forKey: .schemaVersion)
        try fields.encode(startedAt, forKey: .startedAt)
        try fields.encode(duration, forKey: .duration)
        try fields.encode(sampleCount, forKey: .sampleCount)
        try fields.encode(scenario, forKey: .scenario)
        try fields.encode(averageCPUPercent, forKey: .averageCPUPercent)
        try fields.encode(peakCPUPercent, forKey: .peakCPUPercent)
        try fields.encode(averageResidentBytes, forKey: .averageResidentBytes)
        try fields.encode(peakResidentBytes, forKey: .peakResidentBytes)
        try fields.encode(activeDisplayCount, forKey: .activeDisplayCount)
        try fields.encode(activeSessionCount, forKey: .activeSessionCount)
        try fields.encode(activeResourceCount, forKey: .activeResourceCount)
        try fields.encode(sharedResourceCount, forKey: .sharedResourceCount)
        try fields.encode(sharedResourceReferenceCount, forKey: .sharedResourceReferenceCount)
        try fields.encode(resourceCreationCount, forKey: .resourceCreationCount)
        try fields.encode(pauseReasons, forKey: .pauseReasons)
        try fields.encode(chip, forKey: .chip)
        try fields.encode(physicalMemoryBytes, forKey: .physicalMemoryBytes)
        try fields.encode(macOSVersion, forKey: .macOSVersion)
    }

    private static func validateRedactedStrings(
        scenario: String,
        chip: String,
        macOSVersion: String
    ) throws {
        for (field, value) in [
            ("scenario", scenario),
            ("chip", chip),
            ("macOSVersion", macOSVersion),
        ] {
            let lowered = value.lowercased()
            let isAbsolutePath = value.hasPrefix("/") || value.hasPrefix("~")
            let isURL = URL(string: value)?.scheme != nil
            let isMediaName = ["mov", "mp4", "m4v", "avi", "webm"].contains {
                lowered.hasSuffix(".\($0)")
            }
            guard !isAbsolutePath && !isURL && !isMediaName else {
                throw PerformanceDiagnosticReportError.sensitiveFieldValue(field)
            }
        }
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
