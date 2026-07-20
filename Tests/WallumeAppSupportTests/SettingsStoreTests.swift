import Foundation
import XCTest
@testable import WallumeAppSupport

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testDefaultsUseDisabledLoginAndGalleryWithLowPowerPauseEnabled() {
        let store = SettingsStore(defaults: defaults, loginItem: FakeLoginItem(isEnabled: false))

        XCTAssertEqual(
            store.settings,
            ApplicationSettings(launchAtLogin: false, openGalleryAtLaunch: false, pauseInLowPowerMode: true)
        )
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testLegacyOpenGalleryKeyIsDecoded() {
        defaults.set(true, forKey: "openGalleryAtLaunch")

        let store = SettingsStore(defaults: defaults, loginItem: FakeLoginItem(isEnabled: false))

        XCTAssertTrue(store.settings.openGalleryAtLaunch)
    }

    @MainActor
    func testOrdinarySettingsPersistAcrossStoreInstances() {
        let loginItem = FakeLoginItem(isEnabled: false)
        let store = SettingsStore(defaults: defaults, loginItem: loginItem)
        store.setOpenGalleryAtLaunch(true)
        store.setPauseInLowPowerMode(false)

        let reloaded = SettingsStore(defaults: defaults, loginItem: loginItem)
        XCTAssertEqual(
            reloaded.settings,
            ApplicationSettings(launchAtLogin: false, openGalleryAtLaunch: true, pauseInLowPowerMode: false)
        )
    }

    @MainActor
    func testLoginSettingUsesObservedSystemStateAfterSuccessfulRegistration() {
        let loginItem = FakeLoginItem(isEnabled: false)
        let store = SettingsStore(defaults: defaults, loginItem: loginItem)

        store.setLaunchAtLogin(true)

        XCTAssertTrue(store.settings.launchAtLogin)
        XCTAssertEqual(loginItem.registerCallCount, 1)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testInitialLoginSettingUsesSystemStateRatherThanPersistedValue() {
        defaults.set(false, forKey: "launchAtLogin")

        let store = SettingsStore(defaults: defaults, loginItem: FakeLoginItem(isEnabled: true))

        XCTAssertTrue(store.settings.launchAtLogin)
    }

    @MainActor
    func testRegisterFailureKeepsPreviousLaunchAtLoginValueAndUsesSafeError() {
        let store = SettingsStore(defaults: defaults, loginItem: FakeLoginItem(isEnabled: false, registerError: RawSystemError()))

        store.setLaunchAtLogin(true)

        XCTAssertFalse(store.settings.launchAtLogin)
        XCTAssertEqual(store.errorMessage, "无法更新登录启动设置，请稍后重试。")
        XCTAssertFalse(store.errorMessage?.contains("raw system failure") ?? true)
    }

    @MainActor
    func testUnregisterFailureKeepsPreviousLaunchAtLoginValueAndUsesSafeError() {
        let store = SettingsStore(defaults: defaults, loginItem: FakeLoginItem(isEnabled: true, unregisterError: RawSystemError()))

        store.setLaunchAtLogin(false)

        XCTAssertTrue(store.settings.launchAtLogin)
        XCTAssertEqual(store.errorMessage, "无法更新登录启动设置，请稍后重试。")
        XCTAssertFalse(store.errorMessage?.contains("raw system failure") ?? true)
    }
}

private final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    private var enabled: Bool
    private let registerError: Error?
    private let unregisterError: Error?
    private(set) var registerCallCount = 0

    init(isEnabled: Bool, registerError: Error? = nil, unregisterError: Error? = nil) {
        enabled = isEnabled
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    func isEnabled() throws -> Bool { enabled }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        enabled = true
    }

    func unregister() throws {
        if let unregisterError { throw unregisterError }
        enabled = false
    }
}

private struct RawSystemError: LocalizedError {
    var errorDescription: String? { "raw system failure" }
}
