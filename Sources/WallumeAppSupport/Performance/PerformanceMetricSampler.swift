import Foundation
import WallumeCore

public protocol PerformanceMetricSampling: Sendable {
    func sample(at timestamp: Date) async throws -> PerformanceSample
}

/// Serializes access to the process sampler and attaches the service clock's timestamp.
public actor PerformanceMetricSampler: PerformanceMetricSampling {
    private let sampler: any RuntimeMetricSampling

    public init(sampler: any RuntimeMetricSampling = ProcessRuntimeMetricSampler()) {
        self.sampler = sampler
    }

    public func sample(at timestamp: Date) throws -> PerformanceSample {
        let runtimeSample = try sampler.sample()
        return PerformanceSample(
            timestamp: timestamp,
            cpuPercent: runtimeSample.cpuPercent,
            residentBytes: runtimeSample.residentBytes
        )
    }
}
