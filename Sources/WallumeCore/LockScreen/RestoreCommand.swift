import Foundation

public protocol RestoreOutput: AnyObject {
    func writeStdout(_ text: String)
    func writeStderr(_ text: String)
}

public protocol LockScreenRecovering {
    func inspect() throws -> [RecoveryCandidate]
    func restore(id: UUID) throws -> RecoveryReport
}

extension RecoveryCoordinator: LockScreenRecovering {}

public struct RestoreCommand {
    private static let usage = "usage: wallume-restore status | restore <transaction-uuid> | restore-all\n"

    private let recovery: any LockScreenRecovering
    private let output: any RestoreOutput

    public init(recovery: any LockScreenRecovering, output: any RestoreOutput) {
        self.recovery = recovery
        self.output = output
    }

    public func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        _ = environment
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
            default:
                output.writeStderr(Self.usage)
                return 64
            }
        } catch {
            output.writeStderr("wallume-restore: \(error)\n")
            return 1
        }
    }
}
