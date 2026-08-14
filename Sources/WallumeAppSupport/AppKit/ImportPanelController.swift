import AppKit
import UniformTypeIdentifiers

public struct ImportPanelConfiguration: Equatable, Sendable {
    public let allowsMultipleSelection: Bool
    public let canChooseDirectories: Bool
    public let canChooseFiles: Bool
    public static let files = Self(allowsMultipleSelection: true, canChooseDirectories: false, canChooseFiles: true)
    public static let folder = Self(allowsMultipleSelection: true, canChooseDirectories: true, canChooseFiles: false)
}

@MainActor
public final class ImportPanelController {
    public init() {}
    public func chooseFiles() -> [URL] { run(.files) }
    public func chooseFolders() -> [URL] { run(.folder) }

    private func run(_ configuration: ImportPanelConfiguration) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = configuration.allowsMultipleSelection
        panel.canChooseDirectories = configuration.canChooseDirectories
        panel.canChooseFiles = configuration.canChooseFiles
        panel.allowedContentTypes = configuration.canChooseFiles ? [.mpeg4Movie, .quickTimeMovie] : []
        NSApplication.shared.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.urls : []
    }
}
