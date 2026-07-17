import Foundation
import WallumeCore

/// Serializes lock-screen configuration reads and writes, preserving an unreadable file in place.
public actor LockScreenConfigurationStore {
    private let url: URL
    private let files: any FileStore
    private let jsonStore: AtomicJSONStore
    private var value = LockScreenConfiguration.disabled
    private var loadState = LoadState.unloaded
    private var continuations = [UUID: AsyncStream<LockScreenConfiguration>.Continuation]()

    public init(url: URL, files: any FileStore, jsonStore: AtomicJSONStore) {
        self.url = url
        self.files = files
        self.jsonStore = jsonStore
    }

    @discardableResult
    public func load() throws -> LockScreenConfiguration {
        guard files.exists(url) else {
            value = .disabled
            loadState = .loaded
            publish()
            return value
        }

        loadState = .failed
        do {
            let data = try files.read(url)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let schemaVersion = object?["schemaVersion"] as? Int ?? -1
            guard schemaVersion == LockScreenConfiguration.currentSchemaVersion else {
                throw LockScreenConfigurationStoreError.unsupportedSchema(schemaVersion)
            }
            let loaded = try jsonStore.read(LockScreenConfiguration.self, from: url)
            try validate(loaded)
            value = loaded
            loadState = .loaded
        } catch {
            value = .disabled
            throw error
        }

        publish()
        return value
    }

    public func snapshot() -> LockScreenConfiguration { value }

    public func update(_ configuration: LockScreenConfiguration) throws {
        try ensureAcceptsMutations()
        try validate(configuration)
        try jsonStore.write(configuration, to: url)
        value = configuration
        publish()
    }

    public func events() -> AsyncStream<LockScreenConfiguration> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(value)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func ensureAcceptsMutations() throws {
        switch loadState {
        case .loaded: return
        case .unloaded: throw LockScreenConfigurationStoreError.unavailableBeforeLoad
        case .failed: throw LockScreenConfigurationStoreError.unavailableAfterLoadFailure
        }
    }

    private func validate(_ configuration: LockScreenConfiguration) throws {
        guard configuration.schemaVersion == LockScreenConfiguration.currentSchemaVersion else {
            throw LockScreenConfigurationStoreError.unsupportedSchema(configuration.schemaVersion)
        }

        if configuration.isEnabled {
            guard let aerialID = configuration.selectedAerialID, !aerialID.isEmpty else {
                throw LockScreenConfigurationStoreError.enabledConfigurationMissingAerialID
            }
        } else if configuration.selectedAerialID != nil || configuration.activeTransactionID != nil || configuration.lastSyncedMediaID != nil || configuration.lastSyncedAt != nil {
            throw LockScreenConfigurationStoreError.disabledConfigurationContainsSyncState
        }

        if (configuration.lastSyncedMediaID == nil) != (configuration.lastSyncedAt == nil) {
            throw LockScreenConfigurationStoreError.incompleteSyncMetadata
        }
    }

    private func publish() {
        continuations.values.forEach { $0.yield(value) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

public enum LockScreenConfigurationStoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case enabledConfigurationMissingAerialID
    case disabledConfigurationContainsSyncState
    case incompleteSyncMetadata
    case unavailableBeforeLoad
    case unavailableAfterLoadFailure
}

extension LockScreenConfigurationStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version): "不支持的锁屏配置版本：\(version)"
        case .enabledConfigurationMissingAerialID: "启用锁屏同步前必须选择 Aerial 槽"
        case .disabledConfigurationContainsSyncState: "已停用的锁屏配置不能保留同步状态"
        case .incompleteSyncMetadata: "锁屏同步媒体和时间必须同时存在"
        case .unavailableBeforeLoad: "锁屏配置仍在加载，请稍后重试"
        case .unavailableAfterLoadFailure: "锁屏配置读取失败；为保护原文件，本次启动不允许修改"
        }
    }
}

private enum LoadState { case unloaded, loaded, failed }
