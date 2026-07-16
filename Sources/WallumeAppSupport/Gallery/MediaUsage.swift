import Foundation

public struct DisplayReference: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public protocol MediaUsageChecking: Sendable {
    func references(to mediaID: UUID) -> [DisplayReference]
}

public struct EmptyMediaUsageChecker: MediaUsageChecking {
    public init() {}
    public func references(to mediaID: UUID) -> [DisplayReference] { [] }
}

public struct MediaDeletionBlock: Equatable, Sendable {
    public let mediaID: UUID
    public let displays: [DisplayReference]
}
