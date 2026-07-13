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

        let binaryMutations = try patcher.plan(indexData: binary, aerialID: "AERIAL-ONE")
        let mutations = try patcher.plan(indexData: xml, aerialID: "AERIAL-ONE")
        let changed = try patcher.apply(mutations, to: xml)

        XCTAssertEqual(mutations.map(\.choiceIdentity), binaryMutations.map(\.choiceIdentity))
        XCTAssertEqual(
            String(decoding: mutations[0].choiceIdentity.prefix(6), as: UTF8.self),
            "bplist"
        )
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

    func testRestoreTreatsAMissingConfigurationAsAConflictWithoutChangingRoot() throws {
        let original = try fixtureData("index-tahoe")
        let patcher = WallpaperIndexPatcher()
        let mutations = try patcher.plan(indexData: original, aerialID: "AERIAL-ONE")
        let installed = try patcher.apply(mutations, to: original)
        let configurationRemoved = try removingValue(at: mutations[0].path, in: installed)

        let result = try patcher.restore(mutations, in: configurationRemoved)

        XCTAssertEqual(result.conflicts, [mutations[0].path])
        XCTAssertTrue(result.restoredPaths.isEmpty)
        XCTAssertEqual(result.data, configurationRemoved)
    }

    func testRestoreTreatsAShortenedChoicesArrayAsAConflictWithoutOverwritingIt() throws {
        let original = try fixtureData("index-tahoe")
        let patcher = WallpaperIndexPatcher()
        let mutations = try patcher.plan(indexData: original, aerialID: "AERIAL-ONE")
        let installed = try patcher.apply(mutations, to: original)
        let choiceIndex = try XCTUnwrap(
            mutations[0].path.lastIndex(where: {
                if case .index = $0 { return true }
                return false
            })
        )
        let choicesPath = Array(mutations[0].path[..<choiceIndex])
        let choicesRemoved = try replacingValue([], at: choicesPath, in: installed)

        let result = try patcher.restore(mutations, in: choicesRemoved)

        XCTAssertEqual(result.conflicts, [mutations[0].path])
        XCTAssertTrue(result.restoredPaths.isEmpty)
        XCTAssertEqual(result.data, choicesRemoved)
        XCTAssertTrue(try XCTUnwrap(value(at: choicesPath, in: result.data) as? [Any]).isEmpty)
    }

    func testRestoreContinuesAfterAnInvalidPathAndRestoresOtherMutations() throws {
        let original = try indexDataWithTwoDistinctAerialChoices()
        let patcher = WallpaperIndexPatcher()
        let mutations = try patcher.plan(indexData: original, aerialID: "AERIAL-ONE")
        XCTAssertEqual(mutations.count, 2)
        let installed = try patcher.apply(mutations, to: original)
        let firstConfigurationRemoved = try removingValue(at: mutations[0].path, in: installed)

        let result = try patcher.restore(mutations, in: firstConfigurationRemoved)

        XCTAssertEqual(result.conflicts, [mutations[0].path])
        XCTAssertEqual(result.restoredPaths, [mutations[1].path])
        let firstChoice = try XCTUnwrap(
            value(at: Array(mutations[0].path.dropLast()), in: result.data) as? [String: Any]
        )
        XCTAssertNil(firstChoice["Configuration"])
        XCTAssertEqual(
            try value(at: mutations[1].path, in: result.data) as? Data,
            try value(at: mutations[1].path, in: original) as? Data
        )
    }

    func testRestoreContinuesWhenAChoiceWasReplacedWithANonDictionaryValue() throws {
        let original = try indexDataWithTwoDistinctAerialChoices()
        let patcher = WallpaperIndexPatcher()
        let mutations = try patcher.plan(indexData: original, aerialID: "AERIAL-ONE")
        XCTAssertEqual(mutations.count, 2)
        let installed = try patcher.apply(mutations, to: original)
        let firstChoicePath = Array(mutations[0].path.dropLast())
        let externallyChanged = try replacingValue(
            "EXTERNAL-CHOICE",
            at: firstChoicePath,
            in: installed
        )

        let result = try patcher.restore(mutations, in: externallyChanged)

        XCTAssertEqual(result.conflicts, [mutations[0].path])
        XCTAssertEqual(result.restoredPaths, [mutations[1].path])
        XCTAssertEqual(
            try value(at: firstChoicePath, in: result.data) as? String,
            "EXTERNAL-CHOICE"
        )
        XCTAssertEqual(
            try value(at: mutations[1].path, in: result.data) as? Data,
            try value(at: mutations[1].path, in: original) as? Data
        )
    }

    func testRestoreTreatsReorderedAerialChoicesAsConflictsWithoutChangingThem() throws {
        let original = try indexDataWithTwoDistinctAerialChoices()
        let patcher = WallpaperIndexPatcher()
        let mutations = try patcher.plan(indexData: original, aerialID: "AERIAL-ONE")
        let installed = try patcher.apply(mutations, to: original)
        let choicesPath = Array(mutations[0].path.dropLast(2))
        let choices = try XCTUnwrap(value(at: choicesPath, in: installed) as? [Any])
        let reordered = try replacingValue(
            Array(choices.reversed()),
            at: choicesPath,
            in: installed
        )

        let result = try patcher.restore(mutations, in: reordered)

        XCTAssertEqual(result.conflicts, mutations.map(\.path))
        XCTAssertTrue(result.restoredPaths.isEmpty)
        XCTAssertEqual(result.data, reordered)
    }

    func testApplyRejectsReorderedChoicesEvenWhenTheirConfigurationsMatch() throws {
        let original = try indexDataWithDistinctAerialChoicesSharingConfiguration()
        let patcher = WallpaperIndexPatcher()
        let mutations = try patcher.plan(indexData: original, aerialID: "AERIAL-ONE")
        let choicesPath = Array(mutations[0].path.dropLast(2))
        let choices = try XCTUnwrap(value(at: choicesPath, in: original) as? [Any])
        let reordered = try replacingValue(
            Array(choices.reversed()),
            at: choicesPath,
            in: original
        )

        XCTAssertThrowsError(try patcher.apply(mutations, to: reordered)) {
            XCTAssertEqual($0 as? WallpaperIndexError, .staleValue(mutations[0].path))
        }
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

    func testPlanRejectsIndistinguishableAerialChoicesInTheSameChoicesArray() throws {
        let data = try indexDataWithTwoAerialChoices()
        let choicesPath: [PlistPathComponent] = [
            .key("Idle"),
            .key("Content"),
            .key("Choices"),
        ]

        XCTAssertThrowsError(
            try WallpaperIndexPatcher().plan(indexData: data, aerialID: "AERIAL-ONE")
        ) {
            XCTAssertEqual(
                $0 as? WallpaperIndexError,
                .ambiguousChoiceIdentity(choicesPath)
            )
        }
    }

    func testMutationChoiceIdentitySurvivesCodableRoundTrip() throws {
        let mutation = try XCTUnwrap(
            WallpaperIndexPatcher()
                .plan(indexData: fixtureData("index-sonoma"), aerialID: "AERIAL-ONE")
                .first
        )

        let encoded = try PropertyListEncoder().encode(mutation)
        let decoded = try PropertyListDecoder().decode(PlistMutation.self, from: encoded)

        XCTAssertEqual(decoded, mutation)
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

    private func replacingValue(
        _ value: Any,
        at path: [PlistPathComponent],
        in data: Data
    ) throws -> Data {
        var root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        try setValue(value, at: path[...], in: &root)
        return try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }

    private func removingValue(at path: [PlistPathComponent], in data: Data) throws -> Data {
        var root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        try removeValue(at: path[...], in: &root)
        return try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }

    private func indexDataWithTwoAerialChoices() throws -> Data {
        let firstConfiguration = try PropertyListSerialization.data(
            fromPropertyList: ["selectedID": "ORIGINAL-FIRST", "showAsScreenSaver": false],
            format: .binary,
            options: 0
        )
        let secondConfiguration = try PropertyListSerialization.data(
            fromPropertyList: ["selectedID": "ORIGINAL-SECOND", "showAsScreenSaver": false],
            format: .binary,
            options: 0
        )
        return try PropertyListSerialization.data(
            fromPropertyList: [
                "Idle": [
                    "Content": [
                        "Choices": [
                            [
                                "Provider": "com.apple.wallpaper.choice.aerials",
                                "Configuration": firstConfiguration,
                            ],
                            [
                                "Provider": "com.apple.wallpaper.choice.aerials",
                                "Configuration": secondConfiguration,
                            ],
                        ],
                    ],
                ],
            ],
            format: .binary,
            options: 0
        )
    }

    private func indexDataWithTwoDistinctAerialChoices() throws -> Data {
        let firstConfiguration = try PropertyListSerialization.data(
            fromPropertyList: ["selectedID": "ORIGINAL-FIRST", "showAsScreenSaver": false],
            format: .binary,
            options: 0
        )
        let secondConfiguration = try PropertyListSerialization.data(
            fromPropertyList: ["selectedID": "ORIGINAL-SECOND", "showAsScreenSaver": false],
            format: .binary,
            options: 0
        )
        return try PropertyListSerialization.data(
            fromPropertyList: [
                "Idle": [
                    "Content": [
                        "Choices": [
                            [
                                "AssetID": "FIRST",
                                "Provider": "com.apple.wallpaper.choice.aerials",
                                "Configuration": firstConfiguration,
                            ],
                            [
                                "AssetID": "SECOND",
                                "Provider": "com.apple.wallpaper.choice.aerials",
                                "Configuration": secondConfiguration,
                            ],
                        ],
                    ],
                ],
            ],
            format: .binary,
            options: 0
        )
    }

    private func indexDataWithDistinctAerialChoicesSharingConfiguration() throws -> Data {
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["selectedID": "ORIGINAL", "showAsScreenSaver": false],
            format: .binary,
            options: 0
        )
        return try PropertyListSerialization.data(
            fromPropertyList: [
                "Idle": [
                    "Content": [
                        "Choices": [
                            [
                                "AssetID": "FIRST",
                                "Provider": "com.apple.wallpaper.choice.aerials",
                                "Configuration": configuration,
                            ],
                            [
                                "AssetID": "SECOND",
                                "Provider": "com.apple.wallpaper.choice.aerials",
                                "Configuration": configuration,
                            ],
                        ],
                    ],
                ],
            ],
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

    private func removeValue(
        at path: ArraySlice<PlistPathComponent>,
        in root: inout Any
    ) throws {
        guard let component = path.first else {
            XCTFail("Cannot remove the plist root")
            return
        }
        switch component {
        case let .key(key):
            var dictionary = try XCTUnwrap(root as? [String: Any])
            if path.count == 1 {
                dictionary.removeValue(forKey: key)
            } else {
                var child = try XCTUnwrap(dictionary[key])
                try removeValue(at: path.dropFirst(), in: &child)
                dictionary[key] = child
            }
            root = dictionary
        case let .index(index):
            var array = try XCTUnwrap(root as? [Any])
            if path.count == 1 {
                array.remove(at: index)
            } else {
                var child = array[index]
                try removeValue(at: path.dropFirst(), in: &child)
                array[index] = child
            }
            root = array
        }
    }
}
