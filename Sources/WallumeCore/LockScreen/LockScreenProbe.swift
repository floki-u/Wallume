import Foundation

public struct LockScreenProbeReport: Equatable, Sendable {
    public let generation: MacOSGeneration
    public let writesPermitted: Bool
    public let manifestExists: Bool
    public let indexExists: Bool
    public let availableSlots: [AerialSlot]
    public let foreignBackupNames: [String]

    public init(
        generation: MacOSGeneration,
        writesPermitted: Bool,
        manifestExists: Bool,
        indexExists: Bool,
        availableSlots: [AerialSlot],
        foreignBackupNames: [String]
    ) {
        self.generation = generation
        self.writesPermitted = writesPermitted
        self.manifestExists = manifestExists
        self.indexExists = indexExists
        self.availableSlots = availableSlots
        self.foreignBackupNames = foreignBackupNames
    }
}

public struct LockScreenProbe: Sendable {
    private let files: any FileStore

    public init(files: any FileStore) {
        self.files = files
    }

    public func inspect(
        paths: AerialPaths,
        version: OperatingSystemVersion
    ) throws -> LockScreenProbeReport {
        let generation = MacOSGeneration(version: version)
        let manifestExists = files.exists(paths.manifest)
        let indexExists = files.exists(paths.wallpaperIndex)
        let videoDirectoryExists = files.exists(paths.videosDirectory)
        let slots = try availableSlots(
            paths: paths,
            manifestExists: manifestExists,
            videoDirectoryExists: videoDirectoryExists
        )
        let foreignBackupNames = try foreignBackupNames(
            paths: paths,
            videoDirectoryExists: videoDirectoryExists
        )
        return LockScreenProbeReport(
            generation: generation,
            writesPermitted: generation.permitsWrites,
            manifestExists: manifestExists,
            indexExists: indexExists,
            availableSlots: slots,
            foreignBackupNames: foreignBackupNames
        )
    }

    private func availableSlots(
        paths: AerialPaths,
        manifestExists: Bool,
        videoDirectoryExists: Bool
    ) throws -> [AerialSlot] {
        guard manifestExists, videoDirectoryExists else { return [] }
        return try AerialDiscovery(files: files).availableSlots(paths: paths)
    }

    private func foreignBackupNames(
        paths: AerialPaths,
        videoDirectoryExists: Bool
    ) throws -> [String] {
        guard videoDirectoryExists else { return [] }
        return try files.contents(paths.videosDirectory)
            .map(\.lastPathComponent)
            .filter { name in
                guard let videoName = AerialVideoSidecar.foreignSidecarVideoName(from: name) else {
                    return false
                }
                return AerialVideoSidecar.isForeignSidecar(name: name, forVideoName: videoName)
            }
            .sorted()
    }
}
