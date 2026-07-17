import Foundation
import WallumeCore

/// Serializes lock-screen configuration reads and writes, preserving an unreadable file in place.
public actor LockScreenConfigurationStore {
    private static let documentKeys: Set<String> = [
        "schemaVersion",
        "isEnabled",
        "selectedAerialID",
        "activeTransactionID",
        "lastSyncedMediaID",
        "lastSyncedAt",
        "lastResult",
    ]
    private let url: URL
    private let files: any FileStore
    private let jsonStore: AtomicJSONStore
    private let advisoryLock: any AdvisoryLocking
    private var value = LockScreenConfiguration.disabled
    private var loadState = LoadState.unloaded
    private var persistedFile: PersistedConfigurationFile?
    private var continuations = [UUID: AsyncStream<LockScreenConfiguration>.Continuation]()

    public init(
        url: URL,
        files: any FileStore,
        jsonStore: AtomicJSONStore,
        advisoryLock: (any AdvisoryLocking)? = nil
    ) {
        self.url = url
        self.files = files
        self.jsonStore = jsonStore
        self.advisoryLock = advisoryLock ?? FileAdvisoryLock(
            url: url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).lock")
        )
    }

    @discardableResult
    public func load() throws -> LockScreenConfiguration {
        loadState = .failed
        do {
            let token = try advisoryLock.acquire()
            defer { withExtendedLifetime(token) {} }
            if files.exists(url) {
                let loaded = try readValidatedFile()
                value = loaded.configuration
                persistedFile = loaded.file
            } else {
                value = .disabled
                persistedFile = .missing
            }
            loadState = .loaded
        } catch {
            transitionToFailed()
            throw error
        }

        publish()
        return value
    }

    public func snapshot() -> LockScreenConfiguration { value }

    public func update(_ configuration: LockScreenConfiguration) throws {
        try ensureAcceptsMutations()
        try validate(configuration)
        let token: any AdvisoryLockToken
        do {
            token = try advisoryLock.acquire()
        } catch {
            transitionToFailed()
            throw error
        }
        defer { withExtendedLifetime(token) {} }

        do {
            try verifyPersistedFileIsUnchanged()
        } catch {
            transitionToFailed()
            throw error
        }

        try jsonStore.write(configuration, to: url)
        do {
            let reloaded = try readValidatedFile()
            guard reloaded.configuration == configuration else {
                throw LockScreenConfigurationStoreError.configurationChangedExternally
            }
            persistedFile = reloaded.file
        } catch {
            transitionToFailed()
            throw error
        }
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

    private func readValidatedFile() throws -> (
        configuration: LockScreenConfiguration,
        file: PersistedConfigurationFile
    ) {
        guard try files.hasNoSymlinkComponents(url) else {
            throw LockScreenConfigurationStoreError.unsafeConfigurationFile
        }
        let identity = try files.identity(of: url)
        guard identity.isRegularFile else {
            throw LockScreenConfigurationStoreError.unsafeConfigurationFile
        }
        let data = try files.read(url)
        guard try files.hasNoSymlinkComponents(url), try files.identity(of: url) == identity else {
            throw LockScreenConfigurationStoreError.configurationChangedExternally
        }

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let documentKeySet = object.map { Set($0.keys) } ?? []
        let unexpectedKeys = documentKeySet.subtracting(Self.documentKeys)
        guard unexpectedKeys.isEmpty else {
            throw LockScreenConfigurationStoreError.unexpectedFields(unexpectedKeys)
        }
        let schemaVersion = object?["schemaVersion"] as? Int ?? -1
        guard schemaVersion == LockScreenConfiguration.currentSchemaVersion else {
            throw LockScreenConfigurationStoreError.unsupportedSchema(schemaVersion)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let configuration = try decoder.decode(LockScreenConfiguration.self, from: data)
        try validate(configuration)
        return (configuration, .existing(identity: identity, data: data))
    }

    private func verifyPersistedFileIsUnchanged() throws {
        guard let persistedFile else {
            throw LockScreenConfigurationStoreError.configurationChangedExternally
        }
        switch persistedFile {
        case .missing:
            guard !files.exists(url) else {
                throw LockScreenConfigurationStoreError.configurationChangedExternally
            }
        case let .existing(identity, data):
            guard try files.hasNoSymlinkComponents(url) else {
                throw LockScreenConfigurationStoreError.unsafeConfigurationFile
            }
            let currentIdentity = try files.identity(of: url)
            guard currentIdentity == identity, currentIdentity.isRegularFile else {
                throw LockScreenConfigurationStoreError.configurationChangedExternally
            }
            let currentData = try files.read(url)
            guard try files.hasNoSymlinkComponents(url),
                  try files.identity(of: url) == identity,
                  currentData == data else {
                throw LockScreenConfigurationStoreError.configurationChangedExternally
            }
        }
    }

    private func transitionToFailed() {
        value = .disabled
        persistedFile = nil
        loadState = .failed
        publish()
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
    case unexpectedFields(Set<String>)
    case unsafeConfigurationFile
    case configurationChangedExternally
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
        case let .unexpectedFields(fields): "锁屏配置包含不支持的字段：\(fields.sorted().joined(separator: ", "))"
        case .unsafeConfigurationFile: "锁屏配置文件路径不安全"
        case .configurationChangedExternally: "锁屏配置已被外部修改；为保护该文件，本次启动不允许修改"
        case .enabledConfigurationMissingAerialID: "启用锁屏同步前必须选择 Aerial 槽"
        case .disabledConfigurationContainsSyncState: "已停用的锁屏配置不能保留同步状态"
        case .incompleteSyncMetadata: "锁屏同步媒体和时间必须同时存在"
        case .unavailableBeforeLoad: "锁屏配置仍在加载，请稍后重试"
        case .unavailableAfterLoadFailure: "锁屏配置读取失败；为保护原文件，本次启动不允许修改"
        }
    }
}

private enum LoadState { case unloaded, loaded, failed }

private enum PersistedConfigurationFile {
    case missing
    case existing(identity: FileIdentity, data: Data)
}
