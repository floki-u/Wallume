import Foundation
import WallumeCore

public actor LockScreenSyncService {
    private enum Command: Equatable {
        case start
        case evaluate
        case refresh(LockScreenCommandTicket)
        case selectAerialSlot(String, LockScreenCommandTicket)
        case confirmEnable(LockScreenCommandTicket)
        case disableAndRestore(LockScreenCommandTicket)
        case retry(LockScreenCommandTicket)

        var completion: (command: LockScreenSyncCommand, ticket: LockScreenCommandTicket)? {
            switch self {
            case .start, .evaluate: nil
            case let .refresh(ticket): (.refreshProbe, ticket)
            case let .selectAerialSlot(_, ticket): (.selectAerialSlot, ticket)
            case let .confirmEnable(ticket): (.confirmEnable, ticket)
            case let .disableAndRestore(ticket): (.disableAndRestore, ticket)
            case let .retry(ticket): (.retry, ticket)
            }
        }
    }

    private enum FailureReason: String {
        case configurationUnavailable = "锁屏配置不可用，已停止系统写入"
        case probeFailed = "锁屏环境检测失败，已停止系统写入"
        case recoveryInspectionFailed = "锁屏恢复记录检查失败，已停止系统写入"
        case ambiguousRecovery = "存在无法唯一归属的锁屏恢复记录，需要手动修复"
        case missingConfiguredTransaction = "锁屏配置引用的恢复记录缺失，需要手动修复"
        case mismatchedConfiguredTransaction = "锁屏配置与恢复记录不一致，需要手动修复"
        case conflictedTransaction = "锁屏恢复记录存在冲突，需要手动修复"
        case unsupportedRecoveryPhase = "锁屏恢复记录状态无法自动处理，需要手动修复"
        case foreignBackup = "检测到非 Wallume 的壁纸备份，已停止系统写入"
        case invalidSelection = "请选择检测结果中的 Aerial 槽"
        case confirmationUnavailable = "当前状态不能启用锁屏同步"
        case restoreFailed = "恢复系统锁屏壁纸失败，需要重试或手动修复"
        case restoreConflict = "恢复遇到外部修改，已保留恢复材料"
        case installFailed = "锁屏同步失败；启用意图已保留，可重试"
        case invalidInstallResult = "锁屏事务未到达已验证的提交状态，需要修复"
        case retryRequired = "锁屏写入已停止；请重试并重新检查恢复状态"
    }

    private let configurationStore: LockScreenConfigurationStore
    private let systemClient: any LockScreenSystemClient
    private let files: any FileStore
    private let now: @Sendable () -> Date
    private var configuration: LockScreenConfiguration?
    private var probeReport: LockScreenProbeReport?
    private var selectedAerialID: String?
    private var latestInput = LockScreenSyncInput.empty
    private var inputRevision: UInt64 = 0
    private var latestState: LockScreenSyncState = .unconfigured
    private var continuations = [UUID: AsyncStream<LockScreenSyncState>.Continuation]()
    private var commands: [Command] = []
    private var workerTask: Task<Void, Never>?
    private var started = false
    private var acceptingCommands = true
    private var writesTrusted = false
    private var explicitRecoveryEligibleTransactionID: UUID?
    private var completedCommandGeneration: UInt64 = 0
    private var lastCompletedCommand: LockScreenSyncCommand?
    private var lastCompletedCommandTicket: LockScreenCommandTicket?
    private var lastCompletedCommandSucceeded: Bool?
    private var nextCommandTicket: UInt64 = 0
    private var executingTicket: LockScreenCommandTicket?
    private var lastErrorOriginTicket: LockScreenCommandTicket?

    public init(
        configurationStore: LockScreenConfigurationStore,
        systemClient: any LockScreenSystemClient,
        files: any FileStore = LocalFileStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configurationStore = configurationStore
        self.systemClient = systemClient
        self.files = files
        self.now = now
    }

    public func start() {
        guard acceptingCommands, !started, !commands.contains(.start) else { return }
        enqueue(.start)
    }

    public func apply(input: LockScreenSyncInput) {
        guard acceptingCommands else { return }
        latestInput = input
        inputRevision &+= 1
        if started || commands.contains(.start) { enqueue(.evaluate, coalescingEvaluation: true) }
    }

    @discardableResult public func refreshProbe() -> LockScreenCommandTicket? {
        guard acceptingCommands else { return nil }
        let ticket = issueTicket()
        enqueue(.refresh(ticket))
        return ticket
    }

    @discardableResult public func selectAerialSlot(_ aerialID: String) -> LockScreenCommandTicket? {
        guard acceptingCommands else { return nil }
        let ticket = issueTicket()
        enqueue(.selectAerialSlot(aerialID, ticket))
        return ticket
    }

    @discardableResult public func confirmEnable() -> LockScreenCommandTicket? {
        guard acceptingCommands else { return nil }
        let ticket = issueTicket()
        enqueue(.confirmEnable(ticket))
        return ticket
    }

    @discardableResult public func disableAndRestore() -> LockScreenCommandTicket? {
        guard acceptingCommands else { return nil }
        let ticket = issueTicket()
        enqueue(.disableAndRestore(ticket))
        return ticket
    }

    @discardableResult public func retry() -> LockScreenCommandTicket? {
        guard acceptingCommands else { return nil }
        let ticket = issueTicket()
        enqueue(.retry(ticket))
        return ticket
    }

    public func events() -> AsyncStream<LockScreenSyncState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(latestState)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func snapshot() -> LockScreenSyncState { latestState }

    public func waitForIdle() async {
        while let workerTask { await workerTask.value }
    }

    public func stopAcceptingNewCommandsAndWait() async {
        acceptingCommands = false
        await waitForIdle()
    }

    private func enqueue(_ command: Command, coalescingEvaluation: Bool = false) {
        if coalescingEvaluation {
            commands.removeAll { $0 == .evaluate }
        }
        commands.append(command)
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in await self?.drainCommands() }
    }

    private func issueTicket() -> LockScreenCommandTicket {
        nextCommandTicket &+= 1
        return LockScreenCommandTicket(rawValue: nextCommandTicket)
    }

    private func drainCommands() async {
        while !commands.isEmpty {
            let command = commands.removeFirst()
            await execute(command)
        }
        workerTask = nil
    }

    private func execute(_ command: Command) async {
        executingTicket = command.completion?.ticket
        defer { executingTicket = nil }
        switch command {
        case .start:
            guard !started else { return }
            started = true
            await reconcileStartup()
        case .evaluate:
            guard started else { return }
            await evaluateLatestInput()
        case .refresh, .retry:
            guard started else { return }
            if case .refresh = command {
                await refreshProbeOnly()
            } else {
                await reconcileStartup()
            }
        case let .selectAerialSlot(aerialID, _):
            select(aerialID)
        case .confirmEnable:
            await enableAndEvaluate()
        case .disableAndRestore:
            await disable()
        }
        if let completion = command.completion {
            publishCompletion(of: completion.command, ticket: completion.ticket)
        }
    }

    private func reconcileStartup() async {
        writesTrusted = false
        explicitRecoveryEligibleTransactionID = nil
        publish(phase: .probing)
        let loaded: LockScreenConfiguration
        do {
            loaded = try await configurationStore.load()
        } catch {
            configuration = nil
            publishRepair(.configurationUnavailable)
            return
        }
        configuration = loaded
        selectedAerialID = loaded.selectedAerialID

        let probed: LockScreenProbeReport
        do {
            let client = systemClient
            probed = try await Task.detached { try client.probe() }.value
        } catch {
            publishRepair(.probeFailed)
            return
        }
        probeReport = probed

        let candidates: [RecoveryCandidate]
        do {
            let client = systemClient
            candidates = try await Task.detached { try client.inspectRecovery() }.value
        } catch {
            publishRepair(.recoveryInspectionFailed)
            return
        }

        guard probed.foreignBackupNames.isEmpty else {
            publishRepair(.foreignBackup)
            return
        }
        guard probed.writesPermitted else {
            publish(phase: .unsupported)
            return
        }
        guard await align(configuration: loaded, candidates: candidates) else { return }
        writesTrusted = true
        await evaluateLatestInput()
    }

    private func refreshProbeOnly() async {
        let wasTrusted = writesTrusted
        publish(phase: .probing)
        let probed: LockScreenProbeReport
        do {
            let client = systemClient
            probed = try await Task.detached { try client.probe() }.value
        } catch {
            explicitRecoveryEligibleTransactionID = nil
            publishRepair(.probeFailed)
            return
        }
        probeReport = probed
        guard probed.foreignBackupNames.isEmpty else {
            explicitRecoveryEligibleTransactionID = nil
            publishRepair(.foreignBackup)
            return
        }
        guard probed.writesPermitted else {
            writesTrusted = false
            explicitRecoveryEligibleTransactionID = nil
            publish(phase: .unsupported)
            return
        }
        guard wasTrusted else {
            publishRepair(.retryRequired)
            return
        }
        await evaluateLatestInput()
    }

    private func align(
        configuration loaded: LockScreenConfiguration,
        candidates: [RecoveryCandidate]
    ) async -> Bool {
        guard candidates.count <= 1 else {
            publishRepair(.ambiguousRecovery)
            return false
        }

        if let transactionID = loaded.activeTransactionID {
            guard let candidate = candidates.first(where: { $0.id == transactionID }) else {
                publishRepair(.missingConfiguredTransaction)
                return false
            }
            guard candidate.aerialID == loaded.selectedAerialID else {
                publishRepair(.mismatchedConfiguredTransaction)
                return false
            }
            switch candidate.phase {
            case .committed:
                return true
            case .prepared, .writing, .restoring:
                return await restoreConfiguredTransaction(transactionID)
            case .conflicted:
                explicitRecoveryEligibleTransactionID = transactionID
                publishRepair(.conflictedTransaction)
                return false
            case .restored:
                publishRepair(.unsupportedRecoveryPhase)
                return false
            }
        }

        guard let orphan = candidates.first else {
            return true
        }
        guard loaded.isEnabled,
              orphan.phase == .committed,
              orphan.aerialID == loaded.selectedAerialID else {
            publishRepair(.ambiguousRecovery)
            return false
        }
        return await restoreOrphan(orphan.id)
    }

    private func restoreConfiguredTransaction(_ transactionID: UUID) async -> Bool {
        publish(phase: .restoring)
        guard await restoreWithoutConflict(transactionID) else { return false }
        guard let current = configuration else {
            publishRepair(.configurationUnavailable)
            return false
        }
        let cleared = LockScreenConfiguration(
            isEnabled: current.isEnabled,
            selectedAerialID: current.selectedAerialID,
            lastResult: .waiting
        )
        return await persist(cleared)
    }

    private func restoreOrphan(_ transactionID: UUID) async -> Bool {
        publish(phase: .restoring)
        guard await restoreWithoutConflict(transactionID) else { return false }
        guard let current = configuration else {
            publishRepair(.configurationUnavailable)
            return false
        }
        let cleared = LockScreenConfiguration(
            isEnabled: true,
            selectedAerialID: current.selectedAerialID,
            lastResult: .waiting
        )
        return await persist(cleared)
    }

    private func evaluateLatestInput() async {
        guard writesTrusted else { return }
        guard let current = configuration else {
            publishRepair(.configurationUnavailable)
            return
        }
        guard current.isEnabled else {
            publish(phase: .readyToConfigure)
            return
        }
        guard probeReport?.writesPermitted == true else {
            publish(phase: .unsupported)
            return
        }
        guard let media = resolvedMainMedia(from: latestInput) else {
            publish(phase: .waitingForMainWallpaper)
            return
        }
        let evaluatedRevision = inputRevision
        if current.activeTransactionID != nil, current.lastSyncedMediaID == media.id {
            publish(phase: .synced)
            return
        }

        if let activeTransactionID = current.activeTransactionID {
            publish(phase: .restoring)
            guard await restoreWithoutConflict(activeTransactionID) else { return }
            let cleared = LockScreenConfiguration(
                isEnabled: true,
                selectedAerialID: current.selectedAerialID,
                lastResult: .waiting
            )
            guard await persist(cleared) else { return }
            if evaluatedRevision != inputRevision {
                await evaluateLatestInput()
                return
            }
        }
        await install(media)
    }

    private func install(_ media: MediaItem) async {
        guard let current = configuration,
              current.isEnabled,
              let aerialID = current.selectedAerialID else {
            publishRepair(.confirmationUnavailable)
            return
        }
        publish(phase: .syncing)
        let manifest: LockScreenTransactionManifest
        do {
            let client = systemClient
            manifest = try await Task.detached {
                try client.install(media: media, aerialID: aerialID)
            }.value
        } catch {
            await recordInstallFailure(current)
            return
        }
        guard manifest.phase == .committed, manifest.aerialID == aerialID else {
            await recordInstallFailure(current, reason: .invalidInstallResult)
            return
        }
        let installed = LockScreenConfiguration(
            isEnabled: true,
            selectedAerialID: aerialID,
            activeTransactionID: manifest.id,
            lastSyncedMediaID: media.id,
            lastSyncedAt: now(),
            lastResult: .synced
        )
        guard await persist(installed) else { return }
        publish(phase: .synced)
    }

    private func recordInstallFailure(
        _ current: LockScreenConfiguration,
        reason: FailureReason = .installFailed
    ) async {
        let failed = LockScreenConfiguration(
            isEnabled: true,
            selectedAerialID: current.selectedAerialID,
            activeTransactionID: current.activeTransactionID,
            lastSyncedMediaID: current.lastSyncedMediaID,
            lastSyncedAt: current.lastSyncedAt,
            lastResult: .failed
        )
        guard await persist(failed) else { return }
        publishRepair(reason)
    }

    private func select(_ aerialID: String) {
        guard writesTrusted else { return }
        guard configuration?.isEnabled != true,
              probeReport?.availableSlots.contains(where: { $0.id == aerialID }) == true else {
            publishRepair(.invalidSelection, invalidatesTrust: false)
            return
        }
        selectedAerialID = aerialID
        publish(phase: .readyToConfigure)
    }

    private func enableAndEvaluate() async {
        if configuration?.isEnabled == true { return }
        guard started,
              writesTrusted,
              probeReport?.writesPermitted == true,
              probeReport?.foreignBackupNames.isEmpty == true,
              let aerialID = selectedAerialID,
              probeReport?.availableSlots.contains(where: { $0.id == aerialID }) == true else {
            publishRepair(.confirmationUnavailable, invalidatesTrust: false)
            return
        }
        let enabled = LockScreenConfiguration(isEnabled: true, selectedAerialID: aerialID)
        guard await persist(enabled) else { return }
        await evaluateLatestInput()
    }

    private func disable() async {
        guard let current = configuration else {
            publishRepair(.configurationUnavailable)
            return
        }
        guard writesTrusted else {
            await explicitlyRecoverAndDisable(current)
            return
        }
        if let transactionID = current.activeTransactionID {
            publish(phase: .restoring)
            guard await restoreWithoutConflict(transactionID) else { return }
        }
        guard await persist(.disabled) else { return }
        selectedAerialID = nil
        publish(phase: probeReport?.writesPermitted == false ? .unsupported : .readyToConfigure)
    }

    private func explicitlyRecoverAndDisable(_ current: LockScreenConfiguration) async {
        guard let transactionID = current.activeTransactionID,
              transactionID == explicitRecoveryEligibleTransactionID,
              let aerialID = current.selectedAerialID else { return }
        let candidates: [RecoveryCandidate]
        do {
            let client = systemClient
            candidates = try await Task.detached { try client.inspectRecovery() }.value
        } catch {
            explicitRecoveryEligibleTransactionID = nil
            publishRepair(.recoveryInspectionFailed)
            return
        }
        guard candidates.count == 1,
              let candidate = candidates.first,
              candidate.id == transactionID,
              candidate.aerialID == aerialID,
              candidate.phase == .conflicted else {
            explicitRecoveryEligibleTransactionID = nil
            publishRepair(.ambiguousRecovery)
            return
        }
        publish(phase: .restoring)
        guard await restoreWithoutConflict(transactionID) else { return }
        explicitRecoveryEligibleTransactionID = nil
        guard await persist(.disabled) else { return }
        selectedAerialID = nil
        publish(phase: probeReport?.writesPermitted == false ? .unsupported : .readyToConfigure)
    }

    private func restoreWithoutConflict(_ transactionID: UUID) async -> Bool {
        let report: RecoveryReport
        do {
            let client = systemClient
            report = try await Task.detached {
                try client.restore(transactionID: transactionID)
            }.value
        } catch {
            publishRepair(.restoreFailed)
            return false
        }
        guard report.conflicts.isEmpty, report.retainedBackups.isEmpty else {
            publishRepair(.restoreConflict)
            return false
        }
        return true
    }

    private func persist(_ updated: LockScreenConfiguration) async -> Bool {
        do {
            try await configurationStore.update(updated)
            configuration = updated
            selectedAerialID = updated.selectedAerialID
            return true
        } catch {
            configuration = nil
            publishRepair(.configurationUnavailable)
            return false
        }
    }

    private func resolvedMainMedia(from input: LockScreenSyncInput) -> MediaItem? {
        let mainScreens = input.screens.filter(\.isMain)
        guard mainScreens.count == 1,
              let main = mainScreens.first,
              let record = input.assignments.records.first(where: { $0.displayID == main.id }),
              let mediaID = record.mediaID,
              let media = input.mediaByID[mediaID],
              isSafeRegularFile(media.variantURL),
              isSafeRegularFile(media.coverURL) else { return nil }
        return media
    }

    private func isSafeRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL, files.exists(url) else { return false }
        do {
            return try files.hasNoSymlinkComponents(url) && files.identity(of: url).isRegularFile
        } catch {
            return false
        }
    }

    private func publishRepair(_ reason: FailureReason, invalidatesTrust: Bool = true) {
        if invalidatesTrust { writesTrusted = false }
        publish(phase: .needsRepair, error: reason.rawValue)
    }

    private func publishCompletion(of command: LockScreenSyncCommand, ticket: LockScreenCommandTicket) {
        completedCommandGeneration &+= 1
        lastCompletedCommand = command
        lastCompletedCommandTicket = ticket
        lastCompletedCommandSucceeded = latestState.lastError == nil
        publish(phase: latestState.phase, error: latestState.lastError)
    }

    private func publish(phase: LockScreenSyncPhase, error: String? = nil) {
        if error != nil { lastErrorOriginTicket = executingTicket }
        let current = configuration
        let syncedMedia = current?.lastSyncedMediaID.map { id in
            LockScreenSyncedMediaSummary(id: id, displayName: latestInput.mediaByID[id]?.displayName)
        }
        let canSelect = writesTrusted
            && phase == .readyToConfigure
            && !(probeReport?.availableSlots.isEmpty ?? true)
        let canConfirm = phase == .readyToConfigure
            && writesTrusted
            && selectedAerialID != nil
            && current?.isEnabled != true
        let isBusy = phase == .probing || phase == .syncing || phase == .restoring
        let canExplicitlyRecover = phase == .needsRepair
            && explicitRecoveryEligibleTransactionID.map {
                current?.activeTransactionID == $0
            } == true
        latestState = LockScreenSyncState(
            phase: phase,
            selectedAerialID: selectedAerialID,
            probe: probeReport,
            activeTransactionID: current?.activeTransactionID,
            syncedMedia: syncedMedia,
            lastSyncedAt: current?.lastSyncedAt,
            lastResult: current?.lastResult,
            lastError: error,
            errorOriginTicket: error == nil ? nil : lastErrorOriginTicket,
            capabilities: LockScreenSyncCapabilities(
                canRefreshProbe: started && !isBusy,
                canSelectAerialSlot: canSelect,
                canConfirmEnable: canConfirm,
                canDisableAndRestore: current?.isEnabled == true
                    && (writesTrusted || canExplicitlyRecover)
                    && !isBusy,
                canRetry: phase == .needsRepair || phase == .unsupported
            ),
            completedCommandGeneration: completedCommandGeneration,
            lastCompletedCommand: lastCompletedCommand,
            lastCompletedCommandTicket: lastCompletedCommandTicket,
            lastCompletedCommandSucceeded: lastCompletedCommandSucceeded
        )
        continuations.values.forEach { $0.yield(latestState) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
