import Foundation
import WallumeCore

final class StandardMediaOutput: MediaCommandOutput {
    func writeStdout(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

let environment = ProcessInfo.processInfo.environment
let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
let cache = URL(
    fileURLWithPath: environment["XDG_CACHE_HOME"] ?? home.appending(path: "Library/Caches").path,
    isDirectory: true
)
let files = LocalFileStore()
let paths = MediaPaths(homeDirectory: home, cacheDirectory: cache)
let library = MediaLibrary(
    paths: paths,
    files: files,
    jsonStore: AtomicJSONStore(files: files)
)
let importer = MediaImporter(
    paths: paths,
    files: files,
    library: library,
    inspector: AVFoundationMediaInspector(),
    transcoder: AVFoundationMediaTranscoder(),
    artwork: AVFoundationArtworkGenerator()
)
let command = MediaCommand(importer: importer, library: library, output: StandardMediaOutput())
let arguments = Array(CommandLine.arguments.dropFirst())
let code = await command.run(arguments: arguments)
exit(code)
