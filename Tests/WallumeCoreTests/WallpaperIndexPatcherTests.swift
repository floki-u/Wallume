import Foundation
import XCTest
@testable import WallumeCore

final class WallpaperIndexPatcherTests: XCTestCase {
    func testPlansOnlyAerialIdleConfigurationMutationsForEveryKnownSchema() throws {
        for name in ["index-sonoma", "index-sequoia", "index-tahoe"] {
            let data = try fixtureData(name)
            let patcher = WallpaperIndexPatcher()

            let mutations = try patcher.plan(indexData: data, aerialID: "AERIAL-ONE")

            XCTAssertEqual(mutations.count, 1, name)
            XCTAssertTrue(mutations.allSatisfy {
                $0.path.contains(.key("Idle")) && $0.path.last == .key("Configuration")
            }, name)
            let changed = try patcher.apply(mutations, to: data)
            XCTAssertNotEqual(changed, data, name)

            let configuration = try value(at: mutations[0].path, in: changed)
            let configurationData = try XCTUnwrap(configuration as? Data, name)
            let decoded = try PropertyListSerialization.propertyList(
                from: configurationData,
                options: [],
                format: nil
            ) as? [String: Any]
            XCTAssertEqual(decoded?["selectedID"] as? String, "AERIAL-ONE", name)
            XCTAssertEqual(decoded?["showAsScreenSaver"] as? Bool, true, name)
        }
    }

    func testPlansFromXMLInputAndWritesBinaryRootAndBinaryFragments() throws {
        let binary = try fixtureData("index-sonoma")
        let root = try PropertyListSerialization.propertyList(from: binary, options: [], format: nil)
        let xml = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .xml,
            options: 0
        )
        let patcher = WallpaperIndexPatcher()

        let mutations = try patcher.plan(indexData: xml, aerialID: "AERIAL-ONE")
        let changed = try patcher.apply(mutations, to: xml)

        XCTAssertEqual(String(decoding: mutations[0].before.prefix(6), as: UTF8.self), "bplist")
        XCTAssertEqual(String(decoding: mutations[0].after.prefix(6), as: UTF8.self), "bplist")
        XCTAssertEqual(String(decoding: changed.prefix(6), as: UTF8.self), "bplist")
    }

    func testApplyRejectsAStaleValueWithoutChangingInput() throws {
        let original = try fixtureData("index-tahoe")
        let patcher = WallpaperIndexPatcher()
        let mutations = try patcher.plan(indexData: original, aerialID: "AERIAL-ONE")
        let installed = try patcher.apply(mutations, to: original)

        XCTAssertThrowsError(try patcher.apply(mutations, to: installed)) {
            XCTAssertEqual($0 as? WallpaperIndexError, .staleValue(mutations[0].path))
        }
    }

    func testRestoreSkipsAValueChangedAfterWallumeWrite() throws {
        let original = try fixtureData("index-tahoe")
        let patcher = WallpaperIndexPatcher()
        let mutations = try patcher.plan(indexData: original, aerialID: "AERIAL-ONE")
        let installed = try patcher.apply(mutations, to: original)
        let externallyChanged = try replacingValue(
            at: mutations[0].path,
            in: installed,
            withSelectedID: "OTHER-APP"
        )

        let result = try patcher.restore(mutations, in: externallyChanged)

        XCTAssertEqual(result.conflicts, [mutations[0].path])
        XCTAssertTrue(result.restoredPaths.isEmpty)
        XCTAssertEqual(result.data, externallyChanged)
    }

    func testRestoreReinstatesOnlyMatchingAfterValues() throws {
        let original = try fixtureData("index-sonoma")
        let patcher = WallpaperIndexPatcher()
        let mutations = try patcher.plan(indexData: original, aerialID: "AERIAL-ONE")
        let installed = try patcher.apply(mutations, to: original)

        let result = try patcher.restore(mutations, in: installed)

        XCTAssertEqual(result.restoredPaths, mutations.map(\.path))
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(
            try value(at: mutations[0].path, in: result.data) as? Data,
            try value(at: mutations[0].path, in: original) as? Data
        )
    }

    func testPlanRejectsAPlistWithoutAnAerialIdleChoice() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Idle": ["Provider": "com.apple.wallpaper.choice.photos"]],
            format: .binary,
            options: 0
        )

        XCTAssertThrowsError(
            try WallpaperIndexPatcher().plan(indexData: data, aerialID: "AERIAL-ONE")
        ) {
            XCTAssertEqual($0 as? WallpaperIndexError, .noAerialIdleChoice)
        }
    }

    func testPlanRejectsAnAerialChoiceWithNonDataConfiguration() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "Idle": [
                    "Provider": "com.apple.wallpaper.choice.aerials",
                    "Configuration": ["selectedID": "WRONG-SHAPE"],
                ],
            ],
            format: .binary,
            options: 0
        )

        XCTAssertThrowsError(
            try WallpaperIndexPatcher().plan(indexData: data, aerialID: "AERIAL-ONE")
        ) {
            XCTAssertEqual($0 as? WallpaperIndexError, .noAerialIdleChoice)
        }
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "plist",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    private func replacingValue(
        at path: [PlistPathComponent],
        in data: Data,
        withSelectedID selectedID: String
    ) throws -> Data {
        var root = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: nil
        )
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["selectedID": selectedID, "showAsScreenSaver": true],
            format: .binary,
            options: 0
        )
        try setValue(configuration, at: path[...], in: &root)
        return try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }

    private func value(at path: [PlistPathComponent], in data: Data) throws -> Any {
        var value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        for component in path {
            switch component {
            case let .key(key):
                value = try XCTUnwrap((value as? [String: Any])?[key])
            case let .index(index):
                value = (try XCTUnwrap(value as? [Any]))[index]
            }
        }
        return value
    }

    private func setValue(
        _ value: Any,
        at path: ArraySlice<PlistPathComponent>,
        in root: inout Any
    ) throws {
        guard let component = path.first else {
            root = value
            return
        }
        switch component {
        case let .key(key):
            var dictionary = try XCTUnwrap(root as? [String: Any])
            var child = try XCTUnwrap(dictionary[key])
            try setValue(value, at: path.dropFirst(), in: &child)
            dictionary[key] = child
            root = dictionary
        case let .index(index):
            var array = try XCTUnwrap(root as? [Any])
            var child = array[index]
            try setValue(value, at: path.dropFirst(), in: &child)
            array[index] = child
            root = array
        }
    }
}
