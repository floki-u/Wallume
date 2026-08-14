import Foundation

public protocol RestoreOutput: AnyObject {
    func writeStdout(_ text: String)
    func writeStderr(_ text: String)
}

public protocol LockScreenRecovering {
    func inspect() throws -> [RecoveryCandidate]
    func restore(id: UUID) throws -> RecoveryReport
}

public protocol LockScreenProbing {
    func inspect() throws -> LockScreenProbeReport
}

/// Recovery surface for the macOS 26 compatibility registrations. It is separate from legacy
/// slot recovery because Tahoe never owns or restores an Apple-provided video slot.
public protocol TahoeAerialRecovering {
    func inspectTahoe() throws -> [TahoeAerialRecoveryCandidate]
    func resetTahoe(id: UUID) throws -> TahoeAerialResetReport
}

extension RecoveryCoordinator: LockScreenRecovering {}

public struct RestoreCommand {
    private static let usage = "usage: wallume-restore status | probe | restore <transaction-uuid> | restore-all | tahoe-status | tahoe-reset <transaction-uuid> | tahoe-reset-all\n"

    private let recovery: any LockScreenRecovering
    private let tahoeRecovery: (any TahoeAerialRecovering)?
    private let probe: (any LockScreenProbing)?
    private let output: any RestoreOutput

    public init(
        recovery: any LockScreenRecovering,
        probe: (any LockScreenProbing)? = nil,
        tahoeRecovery: (any TahoeAerialRecovering)? = nil,
        output: any RestoreOutput
    ) {
        self.recovery = recovery
        self.probe = probe
        self.tahoeRecovery = tahoeRecovery
        self.output = output
    }

    public func run(arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            output.writeStderr(Self.usage)
            return 64
        }

        do {
            switch command {
            case "status" where arguments.count == 1:
                for candidate in try recovery.inspect() {
                    output.writeStdout(
                        "\(candidate.id.uuidString) \(candidate.phase.rawValue) \(candidate.aerialID)\n"
                    )
                }
                return 0
            case "probe" where arguments.count == 1:
                guard let probe else {
                    output.writeStderr("wallume-restore: probe is not configured\n")
                    return 1
                }
                writeProbeReport(try probe.inspect())
                return 0
            case "restore" where arguments.count == 2:
                guard let id = UUID(uuidString: arguments[1]) else {
                    output.writeStderr(Self.usage)
                    return 64
                }
                return try recovery.restore(id: id).conflicts.isEmpty ? 0 : 2
            case "restore-all" where arguments.count == 1:
                var hadConflict = false
                for candidate in try recovery.inspect() {
                    hadConflict = try !recovery.restore(id: candidate.id).conflicts.isEmpty || hadConflict
                }
                return hadConflict ? 2 : 0
            case "tahoe-status" where arguments.count == 1:
                guard let tahoeRecovery else {
                    output.writeStderr("wallume-restore: Tahoe recovery is not configured\n")
                    return 1
                }
                for candidate in try tahoeRecovery.inspectTahoe() {
                    output.writeStdout(
                        "\(candidate.id.uuidString) \(candidate.phase.rawValue) \(candidate.assetID)\n"
                    )
                }
                return 0
            case "tahoe-reset" where arguments.count == 2:
                guard let tahoeRecovery else {
                    output.writeStderr("wallume-restore: Tahoe recovery is not configured\n")
                    return 1
                }
                guard let id = UUID(uuidString: arguments[1]) else {
                    output.writeStderr(Self.usage)
                    return 64
                }
                return try tahoeRecovery.resetTahoe(id: id).conflicts.isEmpty ? 0 : 2
            case "tahoe-reset-all" where arguments.count == 1:
                guard let tahoeRecovery else {
                    output.writeStderr("wallume-restore: Tahoe recovery is not configured\n")
                    return 1
                }
                var hadConflict = false
                for candidate in try tahoeRecovery.inspectTahoe() {
                    hadConflict = try !tahoeRecovery.resetTahoe(id: candidate.id).conflicts.isEmpty || hadConflict
                }
                return hadConflict ? 2 : 0
            default:
                output.writeStderr(Self.usage)
                return 64
            }
        } catch {
            output.writeStderr("wallume-restore: \(error)\n")
            return 1
        }
    }

    private func writeProbeReport(_ report: LockScreenProbeReport) {
        output.writeStdout("generation: \(generationName(report.generation))\n")
        output.writeStdout("writesPermitted: \(report.writesPermitted)\n")
        output.writeStdout("manifestExists: \(report.manifestExists)\n")
        output.writeStdout("indexExists: \(report.indexExists)\n")
        output.writeStdout("slots: \(joined(report.availableSlots.map(\.id)))\n")
        output.writeStdout("foreignBackups: \(joined(report.foreignBackupNames))\n")
    }

    private func generationName(_ generation: MacOSGeneration) -> String {
        switch generation {
        case .sonoma: "sonoma"
        case .sequoia: "sequoia"
        case .tahoe: "tahoe"
        case let .unsupported(major): "unsupported(\(major))"
        }
    }

    private func joined(_ values: [String]) -> String {
        values.isEmpty ? "-" : values.joined(separator: ",")
    }
}
