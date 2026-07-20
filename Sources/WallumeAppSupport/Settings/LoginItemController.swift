import ServiceManagement

public protocol LoginItemControlling: Sendable {
    func isEnabled() throws -> Bool
    func register() throws
    func unregister() throws
}

public struct MainAppLoginItemController: LoginItemControlling {
    public init() {}

    public func isEnabled() throws -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
