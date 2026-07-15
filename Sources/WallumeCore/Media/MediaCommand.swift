import Foundation

public protocol MediaCommandOutput: AnyObject {
    func writeStdout(_ text: String)
    func writeStderr(_ text: String)
}

public protocol MediaImportingService: Sendable {
    func importURLs(_ urls: [URL]) async throws -> MediaImportReport
}

public protocol MediaLibraryManaging: Sendable {
    func list() throws -> [MediaItem]
    func item(id: UUID) throws -> MediaItem?
    func remove(id: UUID) throws
}

extension MediaImporter: MediaImportingService {}
extension MediaLibrary: MediaLibraryManaging {}

public struct MediaCommand {
    private static let usage = "usage: wallume-media import <path>... | list | show <media-id> | remove <media-id>\n"

    private let importer: any MediaImportingService
    private let library: any MediaLibraryManaging
    private let output: any MediaCommandOutput

    public init(
        importer: any MediaImportingService,
        library: any MediaLibraryManaging,
        output: any MediaCommandOutput
    ) {
        self.importer = importer
        self.library = library
        self.output = output
    }

    public func run(arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            output.writeStderr(Self.usage)
            return 64
        }

        switch command {
        case "import" where arguments.count > 1:
            return await runImport(paths: Array(arguments.dropFirst()))
        case "list" where arguments.count == 1:
            return runList()
        case "show" where arguments.count == 2:
            guard let id = UUID(uuidString: arguments[1]) else {
                output.writeStderr(Self.usage)
                return 64
            }
            return runShow(id: id)
        case "remove" where arguments.count == 2:
            guard let id = UUID(uuidString: arguments[1]) else {
                output.writeStderr(Self.usage)
                return 64
            }
            return runRemove(id: id)
        default:
            output.writeStderr(Self.usage)
            return 64
        }
    }

    private func runImport(paths: [String]) async -> Int32 {
        do {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            let report = try await importer.importURLs(urls)
            var hasFailure = false
            for result in report.results {
                output.writeStdout(line(for: result))
                hasFailure = hasFailure || result.status == .failed || result.status == .cancelled
            }
            return hasFailure ? 1 : 0
        } catch {
            output.writeStderr("wallume-media: \(error)\n")
            return 2
        }
    }

    private func runList() -> Int32 {
        do {
            for item in try library.list() {
                output.writeStdout("\(item.id.uuidString) \(item.displayName) \(item.sourceURL.path)\n")
            }
            return 0
        } catch {
            output.writeStderr("wallume-media: \(error)\n")
            return 2
        }
    }

    private func runShow(id: UUID) -> Int32 {
        do {
            guard let item = try library.item(id: id) else {
                output.writeStderr("wallume-media: media item not found: \(id.uuidString)\n")
                return 2
            }
            output.writeStdout(
                """
                id: \(item.id.uuidString)
                displayName: \(item.displayName)
                sourceURL: \(item.sourceURL.path)
                sourceHash: \(item.sourceHash)
                sourceByteCount: \(item.sourceByteCount)
                dimensions: \(item.pixelWidth)x\(item.pixelHeight)
                frameRate: \(item.frameRate)
                durationSeconds: \(item.durationSeconds)
                codec: \(item.codec)
                variantURL: \(item.variantURL.path)
                thumbnailURL: \(item.thumbnailURL.path)
                coverURL: \(item.coverURL.path)
                createdAt: \(item.createdAt.ISO8601Format())

                """
            )
            return 0
        } catch {
            output.writeStderr("wallume-media: \(error)\n")
            return 2
        }
    }

    private func runRemove(id: UUID) -> Int32 {
        do {
            try library.remove(id: id)
            output.writeStdout("removed \(id.uuidString)\n")
            return 0
        } catch {
            output.writeStderr("wallume-media: \(error)\n")
            return 2
        }
    }

    private func line(for result: MediaImportResult) -> String {
        let file = result.source.lastPathComponent
        switch result.status {
        case .imported:
            return "imported \(file) \(result.item?.id.uuidString ?? "-")\n"
        case .duplicate:
            return "duplicate \(file) \(result.item?.id.uuidString ?? "-")\n"
        case .skipped:
            return "skipped \(file) \(result.message ?? "")\n"
        case .failed:
            return "failed \(file) \(result.message ?? "")\n"
        case .cancelled:
            return "cancelled \(file) \(result.message ?? "")\n"
        }
    }
}
