import Foundation
import WallumeCore

public enum DisplayConnection: Equatable, Sendable {
    case connected
    case disconnected
}

public struct DisplayRecord: Identifiable, Equatable, Sendable {
    public let id: DisplayID
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isMain: Bool
    public let identityPersistence: DisplayIdentityPersistence
    public let connection: DisplayConnection

    public init(screen: DesktopScreen, connection: DisplayConnection = .connected) {
        id = screen.id
        name = screen.name
        pixelWidth = screen.pixelWidth
        pixelHeight = screen.pixelHeight
        isMain = screen.isMain
        identityPersistence = screen.identityPersistence
        self.connection = connection
    }

    public init(record: PersistedDisplayRecord, connection: DisplayConnection = .disconnected) {
        id = record.displayID
        name = record.displayName
        pixelWidth = record.pixelWidth
        pixelHeight = record.pixelHeight
        isMain = record.wasMain
        identityPersistence = record.identityPersistence
        self.connection = connection
    }
}

public enum DisplayCatalog {
    public static func merge(
        connected: [DesktopScreen],
        remembered: [PersistedDisplayRecord]
    ) -> [DisplayRecord] {
        let connectedIDs = Set(connected.map(\.id))
        let online = connected.map { DisplayRecord(screen: $0) }
        let offline = remembered
            .filter { !connectedIDs.contains($0.displayID) }
            .map { DisplayRecord(record: $0) }
        return (online + offline).sorted(by: sort)
    }

    private static func sort(_ lhs: DisplayRecord, _ rhs: DisplayRecord) -> Bool {
        if lhs.connection != rhs.connection { return lhs.connection == .connected }
        if lhs.connection == .connected, lhs.isMain != rhs.isMain { return lhs.isMain }
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
    }
}
