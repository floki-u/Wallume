import Foundation
import os
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    private(set) var isEnabled: Bool = false

    private init() {
        checkStatus()
    }

    func checkStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) async throws {
        let service = SMAppService.mainApp

        if enabled {
            guard service.status != .enabled else {
                isEnabled = true
                return
            }
            do {
                try service.register()
                isEnabled = true
            } catch {
                isEnabled = false
                throw LaunchAtLoginError.registrationFailed(error)
            }
        } else {
            guard service.status == .enabled else {
                isEnabled = false
                return
            }
            do {
                try await service.unregister()
                isEnabled = false
            } catch {
                Log.login.warning("Could not disable launch at login: \(error.localizedDescription)")
                throw LaunchAtLoginError.unregistrationFailed(error)
            }
        }
    }
}

// MARK: - Errors

enum LaunchAtLoginError: LocalizedError {
    case registrationFailed(any Error)
    case unregistrationFailed(any Error)

    var errorDescription: String? {
        switch self {
        case let .registrationFailed(error):
            "Failed to enable launch at login: \(error.localizedDescription)"
        case let .unregistrationFailed(error):
            "Failed to disable launch at login: \(error.localizedDescription)"
        }
    }

    var recoverySuggestion: String? {
        "Please check System Settings \u{2192} General \u{2192} Login Items"
    }
}
