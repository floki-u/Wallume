import Foundation

public enum PlistPathComponent: Codable, Equatable, Sendable {
    case key(String)
    case index(Int)
}

public struct PlistMutation: Codable, Equatable, Sendable {
    public let path: [PlistPathComponent]
    public let choiceIdentity: Data
    public let before: Data
    public let after: Data

    public init(
        path: [PlistPathComponent],
        choiceIdentity: Data,
        before: Data,
        after: Data
    ) {
        self.path = path
        self.choiceIdentity = choiceIdentity
        self.before = before
        self.after = after
    }
}

public struct RestoreOutcome: Equatable, Sendable {
    public let data: Data
    public let restoredPaths: [[PlistPathComponent]]
    public let conflicts: [[PlistPathComponent]]

    public init(
        data: Data,
        restoredPaths: [[PlistPathComponent]],
        conflicts: [[PlistPathComponent]]
    ) {
        self.data = data
        self.restoredPaths = restoredPaths
        self.conflicts = conflicts
    }
}
