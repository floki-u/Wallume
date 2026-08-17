import Foundation
import Observation
import WallumeCore

public enum NativeWallpaperProviderStatus: Equatable, Sendable {
    case unavailable
    case needsMedia
    case readyToPrepare
    case preparedForSystemSelection
    case systemSelectionNeedsUpdate
    case activeInSystem
    case resetConfirmed
    case failure(String)
}

/// Main-actor presentation model for the macOS 26 native wallpaper provider.
///
/// This intentionally never selects or resets a system wallpaper itself. It stages Wallume-owned
/// data and learns about a completed selection from the extension's path-free state signal.
@MainActor @Observable
public final class NativeWallpaperProviderStore {
    public private(set) var status: NativeWallpaperProviderStatus
    public private(set) var media: MediaItem?
    public private(set) var deployment: NativeWallpaperProviderDeployment?

    private let lifecycle: NativeWallpaperProviderLifecycle
    private var pollingTask: Task<Void, Never>?
    private var lastActiveValue = false
    public var onSystemActivationChanged: (@MainActor (Bool) -> Void)?

    public init(
        homeDirectory: URL,
        isSupported: Bool
    ) {
        lifecycle = NativeWallpaperProviderLifecycle(
            paths: NativeWallpaperProviderPaths(homeDirectory: homeDirectory)
        )
        status = isSupported ? .needsMedia : .unavailable
    }

    public func update(mainMedia: MediaItem?) async {
        media = mainMedia
        await reloadDeployment()
        startPollingIfNeeded()
    }

    public func prepareCurrentMedia() async {
        guard status != .unavailable else { return }
        guard let media else {
            status = .needsMedia
            return
        }
        do {
            deployment = try await lifecycle.prepare(
                media: media,
                providerIdentifier: "com.wallume.app.wallpaper"
            )
            status = .preparedForSystemSelection
            notifyActivationIfNeeded(false)
        } catch NativeWallpaperProviderLifecycleError.resetRequired {
            status = .failure("请先在系统壁纸设置中选择其他壁纸，再切换 Wallume 的动态视频。")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    public func refreshSystemSelection() async {
        await reloadDeployment()
    }

    /// The caller has explicitly confirmed that System Settings no longer selects Wallume.
    public func confirmSystemReset() async {
        do {
            try await lifecycle.confirmSystemReset()
            deployment = try await lifecycle.deployment()
            status = .resetConfirmed
            notifyActivationIfNeeded(false)
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    public func cleanupAfterReset() async {
        do {
            try await lifecycle.cleanupAfterReset()
            deployment = nil
            status = media == nil ? .needsMedia : .readyToPrepare
            notifyActivationIfNeeded(false)
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func reloadDeployment() async {
        do {
            deployment = try await lifecycle.reconcileSystemSelection()
            let hasActiveSystemSelection = try await lifecycle.hasActiveSystemSelection()
            if deployment?.isActiveInSystem == true, deployment?.mediaID == media?.id {
                status = .activeInSystem
                notifyActivationIfNeeded(true)
            } else if deployment?.isActiveInSystem == true || hasActiveSystemSelection {
                status = .systemSelectionNeedsUpdate
                notifyActivationIfNeeded(false)
            } else if deployment != nil {
                status = .preparedForSystemSelection
                notifyActivationIfNeeded(false)
            } else {
                status = media == nil ? .needsMedia : .readyToPrepare
                notifyActivationIfNeeded(false)
            }
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.reloadDeployment()
            }
        }
    }

    private func notifyActivationIfNeeded(_ active: Bool) {
        guard active != lastActiveValue else { return }
        lastActiveValue = active
        onSystemActivationChanged?(active)
    }
}
