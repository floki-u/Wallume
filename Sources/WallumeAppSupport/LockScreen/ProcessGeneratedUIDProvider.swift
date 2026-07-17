import Foundation

/// Obtains the generated user identifier required for the lock-screen poster path.
public protocol GeneratedUIDProviding: Sendable {
    func generatedUID(for homeDirectory: URL) throws -> String
}

public enum GeneratedUIDProviderError: Error, Equatable, Sendable {
    case invalidHomeDirectory(URL)
    case commandFailed
    case malformedOutput
}

/// The production provider for the `dscl` GeneratedUID lookup.
///
/// The command closure is injectable so callers can exercise parsing without launching a process.
public struct ProcessGeneratedUIDProvider: GeneratedUIDProviding {
    private let runCommand: @Sendable (URL) throws -> String

    public init() {
        runCommand = Self.runDSCL
    }

    public init(runCommand: @escaping @Sendable (URL) throws -> String) {
        self.runCommand = runCommand
    }

    public func generatedUID(for homeDirectory: URL) throws -> String {
        guard homeDirectory.isFileURL, !homeDirectory.path.isEmpty else {
            throw GeneratedUIDProviderError.invalidHomeDirectory(homeDirectory)
        }

        let output: String
        do {
            output = try runCommand(homeDirectory)
        } catch {
            throw GeneratedUIDProviderError.commandFailed
        }

        guard let value = output
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("GeneratedUID:") })?
            .split(separator: " ", maxSplits: 1)
            .last,
            value != "GeneratedUID:"
        else {
            throw GeneratedUIDProviderError.malformedOutput
        }
        return String(value)
    }

    private static func runDSCL(homeDirectory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "-read", homeDirectory.path, "GeneratedUID"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GeneratedUIDProviderError.commandFailed
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            throw GeneratedUIDProviderError.malformedOutput
        }
        return text
    }
}
