import AppKit
import Foundation

@MainActor
public final class AppKitScreenProvider: DesktopScreenProvider {
    private let notificationCenter: NotificationCenter
    private var observations = [NSObjectProtocol]()
    private var onChange: (@MainActor () -> Void)?

    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    public var screens: [DesktopScreen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber else { return nil }
            return DesktopScreen(
                id: DisplayID(number.stringValue),
                frame: screen.frame
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
