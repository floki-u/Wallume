import XCTest
@testable import WallumeAppSupport

final class LocalizationTests: XCTestCase {
    func testChineseIsTheDefaultLanguage() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "wallume.language")
        defaults.removeObject(forKey: "wallume.language")
        defer { defaults.set(previous, forKey: "wallume.language") }

        XCTAssertEqual(wallumeLocalized("设置"), "设置")
    }

    func testEnglishLanguageResolvesModuleStrings() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "wallume.language")
        defaults.set(WallumeAppLanguage.english.rawValue, forKey: "wallume.language")
        defer { defaults.set(previous, forKey: "wallume.language") }

        XCTAssertEqual(wallumeLocalized("设置"), "Settings")
        XCTAssertEqual(wallumeLocalized("投放到屏幕"), "Project to displays")
    }
}
