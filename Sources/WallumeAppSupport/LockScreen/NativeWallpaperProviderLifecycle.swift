import Foundation
import WallumeCore

/// Owns only Wallume's provider cache. It never reads or writes Apple's wallpaper Store.
///
/// A native wallpaper provider may keep the cached media open after the app exits. Cleanup is
/// therefore blocked until the user has reset the provider selection in System Settings and the
/// host records that reset here.
public struct NativeWallpaperProviderPaths: Sendable, Equatable {
    public let providerIdentifier: String
    public let root: URL
    public let stateFile: URL
    public let providerStateFile: URL
    public let mediaDirectory: URL

    public init(
        homeDirectory: URL,
        providerIdentifier: String = "com.wallume.app.wallpaper"
    ) {
        self.providerIdentifier = providerIdentifier
        root = homeDirectory
            .appending(path: "Library/Containers/\(providerIdentifier)/Data/Documents", directoryHint: .isDirectory)
        stateFile = root.appending(path: "wallume-deployment.json")
        providerStateFile = root.appending(path: "wallume-provider-state.json")
        mediaDirectory = root.appending(path: "videos", directoryHint: .isDirectory)
    }

    public func mediaDirectory(for id: UUID) -> URL {
        mediaDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    public func videoURL(for id: UUID) -> URL {
        mediaDirectory(for: id).appending(path: "wallpaper.mov")
    }

    public func fallbackImageURL(for id: UUID) -> URL {
        mediaDirectory(for: id).appending(path: "fallback.jpg")
    }

    fileprivate func metadataURL(for id: UUID) -> URL {
        mediaDirectory(for: id).appending(path: "metadata.json")
    }
}

/// Durable, path-free provider ownership record. The media paths are deterministic under the
/// private Wallume directory and are intentionally not user-controlled input.
public struct NativeWallpaperProviderDeployment: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let mediaID: UUID
    public let providerIdentifier: String
    public let isActiveInSystem: Bool
    public let deployedAt: Date

    public init(
        mediaID: UUID,
        providerIdentifier: String,
        isActiveInSystem: Bool,
        deployedAt: Date
    ) {
        schemaVersion = Self.schemaVersion
        self.mediaID = mediaID
        self.providerIdentifier = providerIdentifier
        self.isActiveInSystem = isActiveInSystem
        self.deployedAt = deployedAt
    }
}

public enum NativeWallpaperProviderLifecycleError: LocalizedError, Equatable {
    case unsafeSource(URL)
    case invalidProviderIdentifier
    case resetRequired
    case unsupportedState

    public var errorDescription: String? {
        switch self {
        case .unsafeSource:
            "动态壁纸的本地资源无法安全读取。"
        case .invalidProviderIdentifier:
            "动态壁纸提供者标识不匹配。"
        case .resetRequired:
            "请先在系统壁纸设置中改用其他壁纸，再清除 Wallume 的动态壁纸资源。"
        case .unsupportedState:
            "Wallume 的动态壁纸状态文件无法安全读取。"
        }
    }
}

/// Stages one provider-owned video and its already-generated cover image.
///
/// `activateInSystem()` is deliberately separate from `prepare(media:)`: only the native
/// provider host may call it after System Settings has accepted the provider selection.
public actor NativeWallpaperProviderLifecycle {
    private let paths: NativeWallpaperProviderPaths
    private let files: any FileStore
    private let json: AtomicJSONStore
    private let now: @Sendable () -> Date

    public init(
        paths: NativeWallpaperProviderPaths,
        files: any FileStore = LocalFileStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.paths = paths
        self.files = files
        json = AtomicJSONStore(files: files)
        self.now = now
    }

    public func deployment() throws -> NativeWallpaperProviderDeployment? {
        guard files.exists(paths.stateFile) else { return nil }
        guard try files.hasNoSymlinkComponents(paths.stateFile),
              try files.identity(of: paths.stateFile).isRegularFile else {
            throw NativeWallpaperProviderLifecycleError.unsupportedState
        }
        let record = try json.read(NativeWallpaperProviderDeployment.self, from: paths.stateFile)
        guard record.schemaVersion == NativeWallpaperProviderDeployment.schemaVersion else {
            throw NativeWallpaperProviderLifecycleError.unsupportedState
        }
        return record
    }

    /// Copies the playback asset plus a static fallback image into Wallume-owned storage.
    /// Replacing an active provider selection is intentionally rejected until reset completes.
    @discardableResult
    public func prepare(
        media: MediaItem,
        providerIdentifier: String
    ) throws -> NativeWallpaperProviderDeployment {
        guard providerIdentifier == paths.providerIdentifier else {
            throw NativeWallpaperProviderLifecycleError.invalidProviderIdentifier
        }
        guard try isSafeRegularFile(media.variantURL), try isSafeRegularFile(media.coverURL) else {
            throw NativeWallpaperProviderLifecycleError.unsafeSource(media.variantURL)
        }
        if let existing = try deployment(), existing.isActiveInSystem, existing.mediaID != media.id {
            throw NativeWallpaperProviderLifecycleError.resetRequired
        }

        let directory = paths.mediaDirectory(for: media.id)
        try files.createDirectory(paths.root)
        try files.createDirectory(paths.mediaDirectory)
        if files.exists(directory) {
            guard try files.hasNoSymlinkComponents(directory), try files.identity(of: directory).isDirectory else {
                throw NativeWallpaperProviderLifecycleError.unsupportedState
            }
        } else {
            try files.createPrivateDirectory(directory)
        }
        try files.copy(media.variantURL, to: paths.videoURL(for: media.id))
        try files.copy(media.coverURL, to: paths.fallbackImageURL(for: media.id))

        let record = NativeWallpaperProviderDeployment(
            mediaID: media.id,
            providerIdentifier: providerIdentifier,
            isActiveInSystem: false,
            deployedAt: now()
        )
        let metadata = ProviderVideoMetadata(
            id: media.id.uuidString,
            name: media.displayName,
            filename: "wallpaper.mov",
            duration: media.durationSeconds,
            fps: media.frameRate,
            resolution: CGSize(width: media.pixelWidth, height: media.pixelHeight),
            dateAdded: record.deployedAt
        )
        try json.write(metadata, to: paths.metadataURL(for: media.id))
        try json.write(record, to: paths.stateFile)
        postLibraryChangedNotification()
        return record
    }

    /// Reconciles the extension-owned selection signal. The signal carries no filesystem path;
    /// only the deployment record can authorize the media identifier it reports.
    @discardableResult
    public func reconcileSystemSelection() throws -> NativeWallpaperProviderDeployment? {
        guard let record = try deployment() else { return nil }
        guard files.exists(paths.providerStateFile) else { return record }
        guard try files.hasNoSymlinkComponents(paths.providerStateFile),
              try files.identity(of: paths.providerStateFile).isRegularFile else {
            throw NativeWallpaperProviderLifecycleError.unsupportedState
        }
        let state = try json.read(ProviderSelectionState.self, from: paths.providerStateFile)
        guard state.isActive, state.currentVideoID == record.mediaID.uuidString else { return record }
        guard !record.isActiveInSystem else { return record }
        let active = NativeWallpaperProviderDeployment(
            mediaID: record.mediaID,
            providerIdentifier: record.providerIdentifier,
            isActiveInSystem: true,
            deployedAt: record.deployedAt
        )
        try json.write(active, to: paths.stateFile)
        return active
    }

    /// Marks the cache as potentially referenced by WallpaperAgent after a successful selection.
    public func activateInSystem() throws {
        guard let record = try deployment() else { throw NativeWallpaperProviderLifecycleError.unsupportedState }
        try json.write(
            NativeWallpaperProviderDeployment(
                mediaID: record.mediaID,
                providerIdentifier: record.providerIdentifier,
                isActiveInSystem: true,
                deployedAt: record.deployedAt
            ),
            to: paths.stateFile
        )
    }

    /// Call only after the user has reset the system selection away from Wallume's provider.
    public func confirmSystemReset() throws {
        guard let record = try deployment() else { return }
        try json.write(
            NativeWallpaperProviderDeployment(
                mediaID: record.mediaID,
                providerIdentifier: record.providerIdentifier,
                isActiveInSystem: false,
                deployedAt: record.deployedAt
            ),
            to: paths.stateFile
        )
    }

    /// Removes only the deterministic Wallume provider directory. It never removes media from
    /// the main Wallume library and refuses cleanup while a system selection may still reference it.
    public func cleanupAfterReset() throws {
        if let record = try deployment(), record.isActiveInSystem {
            throw NativeWallpaperProviderLifecycleError.resetRequired
        }
        guard files.exists(paths.root) else { return }
        guard try files.hasNoSymlinkComponents(paths.root), try files.identity(of: paths.root).isDirectory else {
            throw NativeWallpaperProviderLifecycleError.unsupportedState
        }
        try files.remove(paths.root)
    }

    private func isSafeRegularFile(_ url: URL) throws -> Bool {
        guard url.isFileURL, files.exists(url), try files.hasNoSymlinkComponents(url) else { return false }
        return try files.identity(of: url).isRegularFile
    }

    private func postLibraryChangedNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.wallume.app.wallpaper.libraryChanged" as CFString),
            nil,
            nil,
            true
        )
    }
}

/// Wire format consumed by the native provider's video discovery code. Keep this local to the
/// deployment boundary so the app does not need to expose private provider implementation types.
private struct ProviderVideoMetadata: Codable, Sendable {
    let id: String
    let name: String
    let filename: String
    let duration: Double
    let fps: Double
    let resolution: CGSize
    let dateAdded: Date
}

private struct ProviderSelectionState: Codable, Sendable {
    let isActive: Bool
    let currentVideoID: String?
}
