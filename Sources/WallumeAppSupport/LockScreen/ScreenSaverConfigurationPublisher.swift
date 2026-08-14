import Foundation
import WallumeCore

/// Publishes only the selected local video path for the separately-installed Wallume screen
/// saver. No system wallpaper or private Aerial manifest is modified.
public struct ScreenSaverConfigurationPublisher: Sendable {
    private let url: URL
    private let files: any FileStore

    public init(homeDirectory: URL, files: any FileStore) {
        url = homeDirectory.appending(path: "Library/Application Support/Wallume/ScreenSaver/config.json")
        self.files = files
    }

    public func publish(media: MediaItem) throws {
        let document = Document(schemaVersion: 1, videoPath: media.variantURL.path, isMuted: true)
        try files.writeAtomically(JSONEncoder().encode(document), to: url)
    }

    private struct Document: Codable, Sendable {
        let schemaVersion: Int
        let videoPath: String
        let isMuted: Bool
    }
}
