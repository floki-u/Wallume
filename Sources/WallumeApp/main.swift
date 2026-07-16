import AppKit

@MainActor
private func launch() {
    let application = NSApplication.shared
    let controller = ApplicationController()
    application.delegate = controller
    application.run()
    withExtendedLifetime(controller) {}
}

launch()
