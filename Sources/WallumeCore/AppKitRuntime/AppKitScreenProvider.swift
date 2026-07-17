import AppKit
import CoreGraphics
import Foundation

public protocol DisplayIdentityProviding: Sendable {
    func identity(for directDisplayID: CGDirectDisplayID) -> DisplayIdentity
}

public struct CoreGraphicsDisplayIdentityProvider: DisplayIdentityProviding {
    public init() {}

    public func identity(for directDisplayID: CGDirectDisplayID) -> DisplayIdentity {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(directDisplayID) else {
            return .fallback(directDisplayID: directDisplayID)
        }
        let uuid = unmanaged.takeRetainedValue()
        let value = CFUUIDCreateString(nil, uuid) as String
        return .uuid(value)
    }
}

@MainActor
public final class AppKitScreenProvider: DesktopScreenProvider {
    private let notificationCenter: NotificationCenter
    private let identityProvider: any DisplayIdentityProviding
    private var observations = [NSObjectProtocol]()
    private var onChange: (@MainActor () -> Void)?

    public init(
        notificationCenter: NotificationCenter = .default,
        identityProvider: any DisplayIdentityProviding = CoreGraphicsDisplayIdentityProvider()
    ) {
        self.notificationCenter = notificationCenter
        self.identityProvider = identityProvider
    }

    public var screens: [DesktopScreen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber else { return nil }
            let directDisplayID = number.uint32Value
            let identity = identityProvider.identity(for: directDisplayID)
            return DesktopScreen(
                id: identity.id,
                frame: screen.frame,
                name: screen.localizedName,
                pixelWidth: Int(CGDisplayPixelsWide(directDisplayID)),
                pixelHeight: Int(CGDisplayPixelsHigh(directDisplayID)),
                isMain: directDisplayID == CGMainDisplayID(),
                identityPersistence: identity.persistence
            )
        }.sorted { $0.id < $1.id }
    }

    public func start(onChange: @escaping @MainActor () -> Void) {
        stop()
        self.onChange = onChange
        let names: [Notification.Name] = [
            NSApplication.didChangeScreenParametersNotification,
            NSApplication.didBecomeActiveNotification,
        ]
        observations = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            }
        }
    }

    public func stop() {
        observations.forEach(notificationCenter.removeObserver)
        observations.removeAll()
        onChange = nil
    }
}
