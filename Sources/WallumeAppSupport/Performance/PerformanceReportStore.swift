import Foundation
import WallumeCore

public protocol PerformanceReportReading: Sendable {
    func latest() throws -> PerformanceDiagnosticReport?
}

public struct PerformanceReportStore: Sendable {
    public let url: URL

    private let diagnosticsDirectory: URL
    private let applicationSupportDirectory: URL
    private let files: any FileStore
    private let jsonStore: AtomicJSONStore

    public init(
        homeDirectory: URL,
        files: any FileStore,
        jsonStore: AtomicJSONStore
    ) {
        applicationSupportDirectory = homeDirectory
            .appending(path: "Library/Application Support")
            .appending(path: WallumeBuildInfo.productName)
        diagnosticsDirectory = applicationSupportDirectory.appending(path: "Diagnostics")
        url = diagnosticsDirectory.appending(path: "report.json")
        self.files = files
        self.jsonStore = jsonStore
    }

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let files = LocalFileStore()
        self.init(
            homeDirectory: homeDirectory,
            files: files,
            jsonStore: AtomicJSONStore(files: files)
        )
    }

    public func save(_ report: PerformanceDiagnosticReport) throws {
        try files.createDirectory(applicationSupportDirectory)
        try files.createPrivateDirectory(diagnosticsDirectory)
        try jsonStore.write(report, to: url)
    }

    public func latest() throws -> PerformanceDiagnosticReport? {
        guard files.exists(url) else { return nil }
        return try jsonStore.read(PerformanceDiagnosticReport.self, from: url)
    }
}

extension PerformanceReportStore: PerformanceReportReading {}
