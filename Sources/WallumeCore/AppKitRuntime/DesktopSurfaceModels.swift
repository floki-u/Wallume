import CoreGraphics
import Foundation

public struct DesktopScreen: Hashable, Sendable {
    public let id: DisplayID
    public let frame: CGRect

    public init(id: DisplayID, frame: CGRect) {
        self.id = id
        self.frame = frame
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
    func setPresentation(_ presentation: PlaybackPresentation?, fallbackURL: URL?)
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
