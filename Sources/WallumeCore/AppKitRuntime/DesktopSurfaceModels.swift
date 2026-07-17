import CoreGraphics
import Foundation

public enum DisplayIdentityPersistence: String, Codable, Sendable {
    case persistent
    case connectionOnly
}

public struct DisplayIdentity: Equatable, Sendable {
    public let id: DisplayID
    public let persistence: DisplayIdentityPersistence

    public init(id: DisplayID, persistence: DisplayIdentityPersistence) {
        self.id = id
        self.persistence = persistence
    }

    public static func uuid(_ value: String) -> Self {
        DisplayIdentity(
            id: DisplayID("cg-uuid:\(value.lowercased())"),
            persistence: .persistent
        )
    }

    public static func fallback(directDisplayID: CGDirectDisplayID) -> Self {
        DisplayIdentity(
            id: DisplayID("cg-direct:\(directDisplayID)"),
            persistence: .connectionOnly
        )
    }
}

public struct DesktopScreen: Hashable, Sendable {
    public let id: DisplayID
    public let frame: CGRect
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isMain: Bool
    public let identityPersistence: DisplayIdentityPersistence

    public init(id: DisplayID, frame: CGRect) {
        self.init(
            id: id,
            frame: frame,
            name: "Display \(id.rawValue)",
            pixelWidth: Int(frame.width.rounded()),
            pixelHeight: Int(frame.height.rounded()),
            isMain: false,
            identityPersistence: .connectionOnly
        )
    }

    public init(
        id: DisplayID,
        frame: CGRect,
        name: String,
        pixelWidth: Int,
        pixelHeight: Int,
        isMain: Bool,
        identityPersistence: DisplayIdentityPersistence
    ) {
        self.id = id
        self.frame = frame
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isMain = isMain
        self.identityPersistence = identityPersistence
    }
}

@MainActor
public protocol DesktopScreenProvider: AnyObject {
    var screens: [DesktopScreen] { get }
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
public protocol DesktopSurface: AnyObject {
    func show(frame: CGRect)
    func setPresentation(
        _ presentation: PlaybackPresentation?,
        fallbackURL: URL?,
        mode: WallpaperPresentationMode
    )
    func close()
}

@MainActor
public protocol PlaybackPresentationRegistry: AnyObject {
    func contains(resourceID: UUID) -> Bool
    func presentationObject(resourceID: UUID) -> AnyObject?
}

@MainActor
public protocol DesktopSurfaceFactory: AnyObject {
    func makeSurface(for screen: DesktopScreen) throws -> any DesktopSurface
}

public struct DesktopSurfaceFailure: Equatable, Sendable {
    public let displayID: DisplayID
    public let message: String

    public init(displayID: DisplayID, message: String) {
        self.displayID = displayID
        self.message = message
    }
}
