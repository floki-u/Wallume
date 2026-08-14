import Foundation
import WallumeCore

/// Serializes lock-screen configuration reads and writes, preserving an unreadable file in place.
///
/// The advisory lock coordinates Wallume processes, while pre/post identity and byte checks detect
/// ordinary external modifications. macOS provides no atomic inode-compare-and-replace operation,
/// so this boundary does not claim protection against a precisely timed same-UID non-cooperating
/// adversary between validation and atomic replacement.
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
        if loadState == .loaded {
            return value
        }
        guard loadState != .failed else {
            throw LockScreenConfigurationStoreError.unavailableAfterLoadFailure
        }
        loadState = .failed
        do {
            guard files.exists(url) else {
                value = .disabled
                persistedFile = .missing
                loadState = .loaded
                publish()
                return value
            }
            let token = try advisoryLock.acquire()
            defer { withExtendedLifetime(token) {} }
            let loaded = try readValidatedFile()
            value = loaded.configuration
            persistedFile = loaded.file
            loadState = .loaded
        } catch {
            recordDiagnostic("initial load rejected", error: error)
            transitionToFailed()
            throw error
        }

        recordDiagnostic("initial load accepted")
        publish()
        return value
    }

    public func snapshot() -> LockScreenConfiguration { value }

    /// Re-establishes trust from the current on-disk document without writing it.
    ///
    /// This is used after an ordinary inode/byte change is detected. The replacement must still
    /// pass the same strict schema, path-safety, and semantic validation as an initial load.
    @discardableResult
    public func reloadTrustedConfiguration() throws -> LockScreenConfiguration {
        do {
            let token = try advisoryLock.acquire()
            defer { withExtendedLifetime(token) {} }
            let loaded = try readValidatedFile()
            value = loaded.configuration
            persistedFile = loaded.file
            loadState = .loaded
            recordDiagnostic("trusted reload accepted")
            publish()
            return value
        } catch {
            recordDiagnostic("trusted reload rejected", error: error)
            transitionToFailed()
            throw error
        }
    }

    /// Explicitly retries a failed initial read without writing the document.
    ///
    /// The app only calls this from a user-requested retry. It retains fail-closed semantics for
    /// malformed or unsafe documents, but avoids trapping a user in a stale failure after a
    /// valid atomic replacement (for example, a completed recovery) is now present on disk.
    @discardableResult
    public func recoverAfterFailure() throws -> LockScreenConfiguration {
        guard loadState == .failed else { return try load() }
        recordDiagnostic("explicit recovery requested")
        return try reloadTrustedConfiguration()
    }

    /// Confirms the source accepted by `load()` or the latest `update(_:)` is still unchanged.
    ///
    /// This intentionally does not reload the file: callers may use it before an irreversible
    /// system mutation without adopting a replacement supplied by another process.
    public func verifyTrustedSource() throws {
        try ensureAcceptsMutations()
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
            recordDiagnostic("trusted source verification rejected", error: error)
            transitionToFailed()
            throw error
        }
    }

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
            recordDiagnostic("configuration update preflight rejected", error: error)
            transitionToFailed()
            throw error
        }

        do {
            try jsonStore.write(configuration, to: url)
        } catch let error as AtomicFileStoreError {
            // A durability uncertainty is reported after the rename may already be visible.
            // Treat it as committed only when a guarded reread proves the exact intended
            // document won; otherwise keep the original fail-closed behavior.
            guard case .durabilityUncertain = error,
                  let reloaded = try? readValidatedFile(),
                  reloaded.configuration == configuration else {
                recordDiagnostic("configuration update write rejected", error: error)
                transitionToFailed()
                throw error
            }
            persistedFile = reloaded.file
            value = configuration
            publish()
            return
        } catch {
            recordDiagnostic("configuration update write rejected", error: error)
            transitionToFailed()
            throw error
        }
        do {
            let written = try readBackWrittenConfiguration(configuration)
            persistedFile = written.file
            value = written.configuration
        } catch {
            recordDiagnostic("configuration update postflight rejected", error: error)
            transitionToFailed()
            throw error
        }
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
        if configuration.lastResult == .restoring {
            guard configuration.activeTransactionID != nil,
                  configuration.lastSyncedMediaID != nil,
                  configuration.lastSyncedAt != nil else {
                throw LockScreenConfigurationStoreError.incompleteRestoreMarker
            }
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
            guard try files.hasNoSymlinkComponents(url), !files.exists(url) else {
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

    /// Confirms the document that we just atomically wrote. This intentionally does not require
    /// two identical inode observations: on Tahoe/APFS, the second no-follow stat may observe a
    /// transient replacement view even though the exact document from this write is present.
    /// Subsequent irreversible work still uses `verifyPersistedFileIsUnchanged()` with the saved
    /// identity and bytes, so an actual later replacement remains fail-closed.
    private func readBackWrittenConfiguration(
        _ expected: LockScreenConfiguration
    ) throws -> (configuration: LockScreenConfiguration, file: PersistedConfigurationFile) {
        guard try files.hasNoSymlinkComponents(url) else {
            throw LockScreenConfigurationStoreError.unsafeConfigurationFile
        }
        let data = try files.read(url)
        guard try files.hasNoSymlinkComponents(url) else {
            throw LockScreenConfigurationStoreError.unsafeConfigurationFile
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reloaded = try decoder.decode(LockScreenConfiguration.self, from: data)
        try validate(reloaded)
        guard representsSamePersistedConfiguration(reloaded, as: expected) else {
            throw LockScreenConfigurationStoreError.configurationChangedExternally
        }
        let identity = try files.identity(of: url)
        guard identity.isRegularFile else {
            throw LockScreenConfigurationStoreError.unsafeConfigurationFile
        }
        return (reloaded, .existing(identity: identity, data: data))
    }

    /// `JSONEncoder.DateEncodingStrategy.iso8601` persists whole seconds. The in-memory `Date`
    /// supplied by `now()` may contain fractional seconds, so direct `Equatable` comparison would
    /// reject our own correctly written document. All non-date fields remain exact.
    private func representsSamePersistedConfiguration(
        _ persisted: LockScreenConfiguration,
        as expected: LockScreenConfiguration
    ) -> Bool {
        persisted.schemaVersion == expected.schemaVersion
            && persisted.isEnabled == expected.isEnabled
            && persisted.selectedAerialID == expected.selectedAerialID
            && persisted.activeTransactionID == expected.activeTransactionID
            && persisted.lastSyncedMediaID == expected.lastSyncedMediaID
            && persisted.lastResult == expected.lastResult
            && samePersistedDate(persisted.lastSyncedAt, expected.lastSyncedAt)
    }

    private func samePersistedDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (.some(left), .some(right)):
            Int(left.timeIntervalSince1970) == Int(right.timeIntervalSince1970)
        default: false
        }
    }

    private func transitionToFailed() {
        value = .disabled
        persistedFile = nil
        loadState = .failed
        publish()
    }

    /// A small, local-only diagnostic trail for user-reported lock-screen failures. Do not log
    /// configuration contents, video paths, hashes, or system-manifest contents here.
    private func recordDiagnostic(_ event: String, error: Error? = nil) {
        let directory = url.deletingLastPathComponent().appending(path: "Diagnostics", directoryHint: .isDirectory)
        let logURL = directory.appending(path: "lock-screen-debug.log")
        let message = error.map { " error=\(String(describing: $0))" } ?? ""
        let line = "\(ISO8601DateFormatter().string(from: Date())) event=\(event)\(message)\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: logURL, options: [.atomic])
            }
        } catch {
            // Diagnostics must never affect the lock-screen recovery path.
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
    case unexpectedFields(Set<String>)
    case unsafeConfigurationFile
    case configurationChangedExternally
    case enabledConfigurationMissingAerialID
    case disabledConfigurationContainsSyncState
    case incompleteSyncMetadata
    case incompleteRestoreMarker
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
        case .incompleteRestoreMarker: "锁屏恢复标记必须引用活动事务和已同步媒体"
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
