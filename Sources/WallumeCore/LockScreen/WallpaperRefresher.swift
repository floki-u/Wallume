public protocol WallpaperRefreshing: Sendable {
    func refresh() throws
}

public enum TransactionFaultPoint: Sendable, Equatable {
    case afterPreparedJournal
    case afterVideoReplacement
    case afterIndexReplacement
    case afterPosterReplacement
    case beforeCommit
}

public protocol FaultInjecting: Sendable {
    func hit(_ point: TransactionFaultPoint) throws
}

public struct NoFaults: FaultInjecting {
    public init() {}
    public func hit(_ point: TransactionFaultPoint) throws {}
}
