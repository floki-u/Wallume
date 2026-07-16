import Darwin
import Foundation

public struct RuntimeMetricSample: Codable, Equatable, Sendable {
    public let residentBytes: UInt64
    public let cpuPercent: Double

    public init(residentBytes: UInt64, cpuPercent: Double) {
        self.residentBytes = residentBytes
        self.cpuPercent = cpuPercent
    }
}

public enum RuntimeBenchmarkScenario: String, Codable, CaseIterable, Sendable {
    case single1080p = "single-1080p"
    case single4K = "single-4k"
    case dualShared = "dual-shared"
    case paused
}

public struct RuntimeBenchmarkConfiguration: Equatable, Sendable {
    public let duration: TimeInterval
    public let scenario: RuntimeBenchmarkScenario

    public init(duration: TimeInterval, scenario: RuntimeBenchmarkScenario) {
        self.duration = duration
        self.scenario = scenario
    }
}

public struct RuntimeLaunchConfiguration: Equatable, Sendable {
    public let mediaID: UUID
    public let benchmark: RuntimeBenchmarkConfiguration?

    public init(mediaID: UUID, benchmark: RuntimeBenchmarkConfiguration?) {
        self.mediaID = mediaID
        self.benchmark = benchmark
    }

    public static func parse(_ arguments: [String]) -> RuntimeLaunchConfiguration? {
        if arguments.count == 1, let mediaID = UUID(uuidString: arguments[0]) {
            return RuntimeLaunchConfiguration(mediaID: mediaID, benchmark: nil)
        }
        guard arguments.count == 6,
              arguments[0] == "benchmark",
              let mediaID = UUID(uuidString: arguments[1]),
              arguments[2] == "--duration",
              let duration = Int(arguments[3]),
              (5...3600).contains(duration),
              arguments[4] == "--scenario",
              let scenario = RuntimeBenchmarkScenario(rawValue: arguments[5]) else {
            return nil
        }
        return RuntimeLaunchConfiguration(
            mediaID: mediaID,
            benchmark: RuntimeBenchmarkConfiguration(
                duration: TimeInterval(duration),
                scenario: scenario
            )
        )
    }
}

public enum GPUVerificationStatus: String, Codable, Sendable {
    case notMeasured
    case pass
    case fail
}

public enum RuntimeCertificationStatus: String, Codable, Sendable {
    case blockedByHardware
}

public struct RuntimeBenchmarkReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let timestamp: Date
    public let scenario: RuntimeBenchmarkScenario
    public let hardwareModel: String
    public let operatingSystem: String
    public let displayCount: Int
    public let mediaWidth: Int?
    public let mediaHeight: Int?
    public let mediaFramesPerSecond: Double?
    public let samples: [RuntimeMetricSample]
    public let sampleCount: Int
    public let averageResidentBytes: UInt64
    public let peakResidentBytes: UInt64
    public let averageCPUPercent: Double
    public let peakCPUPercent: Double
    public let pauseReasons: [RuntimePauseReason]
    public let sharedResourceCount: Int
    public let gpuStatus: GPUVerificationStatus
    public let developmentOnly: Bool
    public let certification: RuntimeCertificationStatus

    public init(
        timestamp: Date,
        scenario: RuntimeBenchmarkScenario,
        hardwareModel: String,
        operatingSystem: String,
        displayCount: Int,
        mediaWidth: Int?,
        mediaHeight: Int?,
        mediaFramesPerSecond: Double?,
        samples: [RuntimeMetricSample],
        pauseReasons: Set<RuntimePauseReason>,
        sharedResourceCount: Int,
        gpuStatus: GPUVerificationStatus
    ) {
        schemaVersion = 1
        self.timestamp = timestamp
        self.scenario = scenario
        self.hardwareModel = hardwareModel
        self.operatingSystem = operatingSystem
        self.displayCount = displayCount
        self.mediaWidth = mediaWidth
        self.mediaHeight = mediaHeight
        self.mediaFramesPerSecond = mediaFramesPerSecond
        self.samples = samples
        sampleCount = samples.count
        if samples.isEmpty {
            averageResidentBytes = 0
            peakResidentBytes = 0
            averageCPUPercent = 0
            peakCPUPercent = 0
        } else {
            averageResidentBytes = samples.map(\.residentBytes).reduce(0, +) / UInt64(samples.count)
            peakResidentBytes = samples.map(\.residentBytes).max() ?? 0
            averageCPUPercent = samples.map(\.cpuPercent).reduce(0, +) / Double(samples.count)
            peakCPUPercent = samples.map(\.cpuPercent).max() ?? 0
        }
        self.pauseReasons = pauseReasons.sorted { $0.rawValue < $1.rawValue }
        self.sharedResourceCount = sharedResourceCount
        self.gpuStatus = gpuStatus
        developmentOnly = true
        certification = .blockedByHardware
    }
}

public protocol RuntimeMetricSampling: AnyObject {
    func sample() throws -> RuntimeMetricSample
}

public enum RuntimeMetricSamplingError: Error {
    case taskInfo(kern_return_t)
    case resourceUsage
}

public final class ProcessRuntimeMetricSampler: RuntimeMetricSampling {
    private var previousUptime: TimeInterval
    private var previousCPUTime: TimeInterval

    public init() {
        previousUptime = ProcessInfo.processInfo.systemUptime
        previousCPUTime = Self.processCPUTime() ?? 0
    }

    public func sample() throws -> RuntimeMetricSample {
        let residentBytes = try Self.residentBytes()
        guard let currentCPUTime = Self.processCPUTime() else {
            throw RuntimeMetricSamplingError.resourceUsage
        }
        let currentUptime = ProcessInfo.processInfo.systemUptime
        let elapsed = max(currentUptime - previousUptime, .leastNonzeroMagnitude)
        let cpuElapsed = max(currentCPUTime - previousCPUTime, 0)
        previousUptime = currentUptime
        previousCPUTime = currentCPUTime
        return RuntimeMetricSample(
            residentBytes: residentBytes,
            cpuPercent: cpuElapsed / elapsed * 100
        )
    }

    private static func residentBytes() throws -> UInt64 {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw RuntimeMetricSamplingError.taskInfo(result) }
        return UInt64(information.resident_size)
    }

    private static func processCPUTime() -> TimeInterval? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return timeInterval(usage.ru_utime) + timeInterval(usage.ru_stime)
    }

    private static func timeInterval(_ value: timeval) -> TimeInterval {
        TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000
    }
}

public enum RuntimeHostInfo {
    public static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    public static var operatingSystem: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}
