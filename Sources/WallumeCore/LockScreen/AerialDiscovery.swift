import Foundation

public struct AerialSlot: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let videoURL: URL

    public init(id: String, displayName: String, videoURL: URL) {
        self.id = id
        self.displayName = displayName
        self.videoURL = videoURL
    }
}

public enum AerialDiscoveryError: Error, Equatable {
    case malformedManifest
    case slotNotFound(String)
    case foreignModificationDetected(String)
}

enum AerialVideoSidecar {
    static func wallumeBackupName(for videoName: String) -> String {
        videoName + WallumeBuildInfo.backupMarker
    }

    static func isForeignSidecar(name: String, forVideoName videoName: String) -> Bool {
        name.hasPrefix(videoName + ".") && name != wallumeBackupName(for: videoName)
    }

    static func foreignSidecarVideoName(from name: String) -> String? {
        guard let movRange = name.range(of: ".mov.") else { return nil }
        return String(String(name[..<movRange.upperBound]).dropLast())
    }
}

public struct AerialDiscovery: Sendable {
    private struct Manifest: Decodable {
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let id: String
        let accessibilityLabel: String?
    }

    private let files: any FileStore

    public init(files: any FileStore) {
        self.files = files
    }

    public func availableSlots(paths: AerialPaths) throws -> [AerialSlot] {
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: files.read(paths.manifest))
        } catch {
            throw AerialDiscoveryError.malformedManifest
        }

        var labels: [String: String] = [:]
        for asset in manifest.assets {
            guard labels[asset.id] == nil else {
                throw AerialDiscoveryError.malformedManifest
            }
            labels[asset.id] = asset.accessibilityLabel ?? asset.id
        }

        return try files.contents(paths.videosDirectory)
            .filter { $0.pathExtension.lowercased() == "mov" }
            .compactMap { videoURL in
                let id = videoURL.deletingPathExtension().lastPathComponent
                guard let displayName = labels[id] else {
                    return nil
                }
                return AerialSlot(id: id, displayName: displayName, videoURL: videoURL)
            }
            .sorted { $0.id < $1.id }
    }

    public func selectSlot(id: String, paths: AerialPaths) throws -> AerialSlot {
        guard let slot = try availableSlots(paths: paths).first(where: { $0.id == id }) else {
            throw AerialDiscoveryError.slotNotFound(id)
        }

        let videoName = slot.videoURL.lastPathComponent
        let hasForeignModification = try files.contents(paths.videosDirectory).contains { url in
            AerialVideoSidecar.isForeignSidecar(
                name: url.lastPathComponent,
                forVideoName: videoName
            )
        }
        guard !hasForeignModification else {
            throw AerialDiscoveryError.foreignModificationDetected(id)
        }
        return slot
    }
}
