import Foundation

enum PathRequirement {
    case existingRegularFile
    case regularFileIfPresent
    case existingDirectory
    case directoryIfPresent
}

struct PathSafetyValidator: Sendable {
    let files: any FileStore

    func accepts(_ url: URL, as requirement: PathRequirement) throws -> Bool {
        guard try files.hasNoSymlinkComponents(url) else { return false }
        guard files.exists(url) else {
            switch requirement {
            case .regularFileIfPresent, .directoryIfPresent: return true
            case .existingRegularFile, .existingDirectory: return false
            }
        }
        let identity = try files.identity(of: url)
        switch requirement {
        case .existingRegularFile, .regularFileIfPresent:
            return identity.isRegularFile
        case .existingDirectory, .directoryIfPresent:
            return identity.isDirectory
        }
    }
}
