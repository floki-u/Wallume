import Foundation
import WallumeCore

final class ProcessOutput: RestoreOutput {
    func writeStdout(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

func currentGeneratedUID(homeDirectory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
    process.arguments = [".", "-read", homeDirectory.path, "GeneratedUID"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileReadUnknown)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8),
          let value = output
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("GeneratedUID:") })?
            .split(separator: " ", maxSplits: 1)
            .last
    else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return String(value)
}

final class ProcessRecovery: LockScreenRecovering {
    private let homeDirectory: URL
    private var coordinator: RecoveryCoordinator?

    init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    func inspect() throws -> [RecoveryCandidate] {
        let placeholderPaths = AerialPaths(homeDirectory: homeDirectory, userGeneratedID: "UNKNOWN")
        guard FileManager.default.fileExists(atPath: placeholderPaths.transactionsDirectory.path) else {
            return []
        }
        return try recovery().inspect()
    }

    func restore(id: UUID) throws -> RecoveryReport {
        try recovery().restore(id: id)
    }

    private func recovery() throws -> RecoveryCoordinator {
        if let coordinator { return coordinator }
        let paths = AerialPaths(
            homeDirectory: homeDirectory,
            userGeneratedID: try currentGeneratedUID(homeDirectory: homeDirectory)
        )
        let files = LocalFileStore()
        let coordinator = RecoveryCoordinator(
            paths: paths,
            files: files,
            digester: SHA256Digester(),
            journals: AtomicJSONStore(files: files),
            patcher: WallpaperIndexPatcher(),
            refresher: ProcessWallpaperRefresher()
        )
        self.coordinator = coordinator
        return coordinator
    }
}

final class ProcessProbe: LockScreenProbing {
    private let homeDirectory: URL

    init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    func inspect() throws -> LockScreenProbeReport {
        let paths = AerialPaths(
            homeDirectory: homeDirectory,
            userGeneratedID: try currentGeneratedUID(homeDirectory: homeDirectory)
        )
        return try LockScreenProbe(files: LocalFileStore()).inspect(
            paths: paths,
            version: ProcessInfo.processInfo.operatingSystemVersion
        )
    }
}

let output = ProcessOutput()
let environment = ProcessInfo.processInfo.environment
let homeDirectory = URL(
    fileURLWithPath: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
    isDirectory: true
)
let recovery = ProcessRecovery(homeDirectory: homeDirectory)
let probe = ProcessProbe(homeDirectory: homeDirectory)
let command = RestoreCommand(recovery: recovery, probe: probe, output: output)
exit(command.run(arguments: Array(CommandLine.arguments.dropFirst())))
