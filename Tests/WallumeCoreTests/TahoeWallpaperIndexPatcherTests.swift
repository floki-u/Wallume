import Foundation
import XCTest
@testable import WallumeCore

final class TahoeWallpaperIndexPatcherTests: XCTestCase {
    func testReplacesOnlySelectedDisplayIdleTargetsAcrossSpacesAndRestoresExactly() throws {
        let original = try fixture()
        let patcher = TahoeWallpaperIndexPatcher()

        let mutations = try patcher.plan(
            indexData: original,
            aerialID: "WALLUME-ASSET",
            targetDisplayID: "cg-uuid:11111111-1111-4111-8111-111111111111"
        )
        XCTAssertEqual(mutations.count, 3)
        XCTAssertTrue(mutations.allSatisfy { $0.path.last == .key("Idle") })

        let installed = try patcher.apply(mutations, to: original)
        let providers = try idleProviders(in: installed)
        XCTAssertEqual(providers.filter { $0 == "com.apple.wallpaper.choice.aerials" }.count, 3)
        XCTAssertEqual(providers.filter { $0 == "com.apple.wallpaper.choice.sequoia" }.count, 1)
        XCTAssertEqual(providers.filter { $0 == "foreign-display" }.count, 1)
        XCTAssertEqual(try aerialIDs(in: installed).compactMap { $0 }, ["WALLUME-ASSET", "WALLUME-ASSET", "WALLUME-ASSET"])

        let restored = try patcher.restore(mutations, in: installed)
        XCTAssertTrue(restored.conflicts.isEmpty)
        let originalRoot = try PropertyListSerialization.propertyList(from: original, format: nil) as? NSDictionary
        let restoredRoot = try PropertyListSerialization.propertyList(from: restored.data, format: nil) as? NSDictionary
        XCTAssertEqual(originalRoot, restoredRoot)
    }

    func testRestoreDoesNotOverwriteAnIdleChoiceChangedByAnotherTool() throws {
        let original = try fixture()
        let patcher = TahoeWallpaperIndexPatcher()
        let mutations = try patcher.plan(
            indexData: original,
            aerialID: "WALLUME-ASSET",
            targetDisplayID: "cg-uuid:11111111-1111-4111-8111-111111111111"
        )
        let installed = try patcher.apply(mutations, to: original)
        var root = try XCTUnwrap(PropertyListSerialization.propertyList(from: installed, format: nil) as? [String: Any])
        var displays = try XCTUnwrap(root["Displays"] as? [String: Any])
        var display = try XCTUnwrap(displays["11111111-1111-4111-8111-111111111111"] as? [String: Any])
        var idle = try XCTUnwrap(display["Idle"] as? [String: Any])
        var content = try XCTUnwrap(idle["Content"] as? [String: Any])
        content["Choices"] = [["Provider": "external-tool"]]
        idle["Content"] = content
        display["Idle"] = idle
        displays["11111111-1111-4111-8111-111111111111"] = display
        root["Displays"] = displays
        let changed = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)

        let result = try patcher.restore(mutations, in: changed)
        XCTAssertEqual(result.conflicts, [[.key("Displays"), .key("11111111-1111-4111-8111-111111111111"), .key("Idle")]])
        XCTAssertEqual(result.restoredPaths.count, 2)
    }

    func testRestoreOldFullIdleMutationPreservesAgentUpdatedTimestamps() throws {
        let original = try fixture()
        let patcher = TahoeWallpaperIndexPatcher()
        let mutations = try patcher.plan(
            indexData: original,
            aerialID: "WALLUME-ASSET",
            targetDisplayID: "cg-uuid:11111111-1111-4111-8111-111111111111"
        )
        let installed = try patcher.apply(mutations, to: original)
        var root = try XCTUnwrap(PropertyListSerialization.propertyList(from: installed, format: nil) as? [String: Any])
        var displays = try XCTUnwrap(root["Displays"] as? [String: Any])
        var display = try XCTUnwrap(displays["11111111-1111-4111-8111-111111111111"] as? [String: Any])
        var idle = try XCTUnwrap(display["Idle"] as? [String: Any])
        idle["LastUse"] = Date(timeIntervalSince1970: 999)
        display["Idle"] = idle
        displays["11111111-1111-4111-8111-111111111111"] = display
        root["Displays"] = displays
        let agentUpdated = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)

        let result = try patcher.restore(mutations, in: agentUpdated)
        XCTAssertTrue(result.conflicts.isEmpty)
        let restored = try XCTUnwrap(PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any])
        let restoredDisplays = try XCTUnwrap(restored["Displays"] as? [String: Any])
        let restoredDisplay = try XCTUnwrap(restoredDisplays["11111111-1111-4111-8111-111111111111"] as? [String: Any])
        let restoredIdle = try XCTUnwrap(restoredDisplay["Idle"] as? [String: Any])
        XCTAssertEqual(restoredIdle["LastUse"] as? Date, Date(timeIntervalSince1970: 999))
        let content = try XCTUnwrap(restoredIdle["Content"] as? [String: Any])
        let choices = try XCTUnwrap(content["Choices"] as? [[String: Any]])
        XCTAssertEqual(choices.first?["Provider"] as? String, "com.apple.wallpaper.choice.screen-saver")
    }

    func testUsesExistingGlobalAutomaticModeOnlyWhenDisplayTargetsAreAbsent() throws {
        let global = try globalAutomaticFixture()
        let patcher = TahoeWallpaperIndexPatcher()

        let mutations = try patcher.plan(
            indexData: global,
            aerialID: "WALLUME-ASSET",
            targetDisplayID: "cg-uuid:11111111-1111-4111-8111-111111111111"
        )
        XCTAssertEqual(mutations.map(\.path), [
            [.key("AllSpacesAndDisplays"), .key("Linked")],
            [.key("SystemDefault"), .key("Linked")],
        ])

        let installed = try patcher.apply(mutations, to: global)
        let restored = try patcher.restore(mutations, in: installed)
        XCTAssertTrue(restored.conflicts.isEmpty)
        let originalRoot = try PropertyListSerialization.propertyList(from: global, format: nil) as? NSDictionary
        let restoredRoot = try PropertyListSerialization.propertyList(from: restored.data, format: nil) as? NSDictionary
        XCTAssertEqual(originalRoot, restoredRoot)
    }

    private func fixture() throws -> Data {
        func entry(provider: String) -> [String: Any] {
            [
                "Content": ["Choices": [["Provider": provider, "Files": [Any]()]]],
                "LastSet": Date(timeIntervalSince1970: 10),
                "LastUse": Date(timeIntervalSince1970: 11),
            ]
        }
        return try PropertyListSerialization.data(
            fromPropertyList: [
                "Idle": entry(provider: "com.apple.wallpaper.choice.sequoia"),
                "Displays": [
                    "11111111-1111-4111-8111-111111111111": ["Idle": entry(provider: "com.apple.wallpaper.choice.screen-saver")],
                    "22222222-2222-4222-8222-222222222222": ["Idle": entry(provider: "foreign-display")],
                ],
                "Spaces": [
                    "": ["Displays": ["11111111-1111-4111-8111-111111111111": ["Idle": entry(provider: "default")]]],
                    "current-space": ["Displays": ["11111111-1111-4111-8111-111111111111": ["Idle": entry(provider: "com.apple.wallpaper.choice.macintosh")]]],
                ],
            ],
            format: .binary,
            options: 0
        )
    }

    private func globalAutomaticFixture() throws -> Data {
        func linked(provider: String) -> [String: Any] {
            [
                "Content": ["Choices": [["Provider": provider, "Files": [Any]()]]],
                "LastSet": Date(timeIntervalSince1970: 10),
                "LastUse": Date(timeIntervalSince1970: 11),
            ]
        }
        return try PropertyListSerialization.data(
            fromPropertyList: [
                "AllSpacesAndDisplays": ["Type": "linked", "Linked": linked(provider: "default")],
                "SystemDefault": ["Type": "linked", "Linked": linked(provider: "default")],
                "Displays": [String: Any](),
                "Spaces": [String: Any](),
            ],
            format: .binary,
            options: 0
        )
    }

    private func idleProviders(in data: Data) throws -> [String] {
        try idleChoices(in: data).map { try XCTUnwrap($0["Provider"] as? String) }
    }

    private func aerialIDs(in data: Data) throws -> [String?] {
        try idleChoices(in: data).map {
            guard let data = $0["Configuration"] as? Data,
                  let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return value["assetID"] as? String
        }
    }

    private func idleChoices(in data: Data) throws -> [[String: Any]] {
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        var choices: [[String: Any]] = []
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let idle = dictionary["Idle"] as? [String: Any],
                   let content = idle["Content"] as? [String: Any],
                   let idleChoices = content["Choices"] as? [[String: Any]] {
                    choices += idleChoices
                }
                dictionary.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(root)
        return choices
    }
}
