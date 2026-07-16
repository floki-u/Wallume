import Foundation

public struct ImportScanWarning: Equatable, Sendable {
    public let url: URL
    public let message: String

    public init(url: URL, message: String) {
        self.url = url
        self.message = message
    }
}

public struct ImportScanResult: Equatable, Sendable {
    public let candidates: [URL]
    public let warnings: [ImportScanWarning]

    public init(candidates: [URL], warnings: [ImportScanWarning]) {
        self.candidates = candidates
        self.warnings = warnings
    }
}

public protocol ImportScanning: Sendable {
    func scan(_ urls: [URL]) -> ImportScanResult
}

public struct LocalImportScanner: ImportScanning {
    public init() {}

    public func scan(_ urls: [URL]) -> ImportScanResult {
        var candidates = [String: URL]()
        var warnings = [ImportScanWarning]()
        for url in urls {
            append(
                url.standardizedFileURL,
                candidates: &candidates,
                warnings: &warnings
            )
        }
        return ImportScanResult(
            candidates: candidates.values.sorted(by: Self.pathOrder),
            warnings: warnings.sorted { Self.pathOrder($0.url, $1.url) }
        )
    }

    private func append(
        _ url: URL,
        candidates: inout [String: URL],
        warnings: inout [ImportScanWarning]
    ) {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isHiddenKey,
                .isPackageKey,
            ])
            let hidden = values.isHidden == true || url.lastPathComponent.hasPrefix(".")
            guard !hidden else { return }
            if values.isRegularFile == true {
                guard Self.isSupportedMedia(url) else { return }
                candidates[url.path] = url
                return
            }
            guard values.isDirectory == true, values.isPackage != true else { return }
            let children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey, .isPackageKey],
                options: []
            ).sorted(by: Self.pathOrder)
            for child in children {
                append(child.standardizedFileURL, candidates: &candidates, warnings: &warnings)
            }
        } catch {
            warnings.append(ImportScanWarning(
                url: url,
                message: error.localizedDescription
            ))
        }
    }

    private static func isSupportedMedia(_ url: URL) -> Bool {
        ["mov", "mp4"].contains(url.pathExtension.lowercased())
    }

    private static func pathOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
}
