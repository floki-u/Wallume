import Foundation

public enum WallpaperIndexError: Error, Equatable {
    case invalidPropertyList
    case noAerialIdleChoice
    case staleValue([PlistPathComponent])
    case invalidPath([PlistPathComponent])
    case ambiguousChoiceIdentity([PlistPathComponent])
}

public struct WallpaperIndexPatcher: Sendable {
    private static let aerialProvider = "com.apple.wallpaper.choice.aerials"

    public init() {}

    public func plan(indexData: Data, aerialID: String) throws -> [PlistMutation] {
        let root = try decode(indexData)
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: [
                "selectedID": aerialID,
                "showAsScreenSaver": true,
            ],
            format: .binary,
            options: 0
        )
        let after = try fragment(for: configuration)
        var mutations: [PlistMutation] = []
        try findAerialIdleChoices(
            in: root,
            path: [],
            isBelowIdle: false,
            after: after,
            mutations: &mutations
        )
        guard !mutations.isEmpty else {
            throw WallpaperIndexError.noAerialIdleChoice
        }
        try validateUniqueChoiceIdentities(mutations)
        return mutations
    }

    public func apply(_ mutations: [PlistMutation], to indexData: Data) throws -> Data {
        var root = try decode(indexData)
        for mutation in mutations {
            let choicePath = Array(mutation.path.dropLast())
            let choice = try value(at: choicePath[...], in: root, fullPath: mutation.path)
            guard try choiceIdentity(for: choice) == mutation.choiceIdentity else {
                throw WallpaperIndexError.staleValue(mutation.path)
            }
            let current = try value(at: mutation.path[...], in: root, fullPath: mutation.path)
            guard try fragment(for: current) == mutation.before else {
                throw WallpaperIndexError.staleValue(mutation.path)
            }
            let replacement = try decode(mutation.after)
            try setValue(
                replacement,
                at: mutation.path[...],
                in: &root,
                fullPath: mutation.path
            )
        }
        return try encodeRoot(root)
    }

    public func restore(
        _ mutations: [PlistMutation],
        in indexData: Data
    ) throws -> RestoreOutcome {
        var root = try decode(indexData)
        var restoredPaths: [[PlistPathComponent]] = []
        var conflicts: [[PlistPathComponent]] = []

        for mutation in mutations {
            let current: Any
            do {
                let choicePath = Array(mutation.path.dropLast())
                let choice = try value(at: choicePath[...], in: root, fullPath: mutation.path)
                guard try choiceIdentity(for: choice) == mutation.choiceIdentity else {
                    conflicts.append(mutation.path)
                    continue
                }
                current = try value(at: mutation.path[...], in: root, fullPath: mutation.path)
            } catch WallpaperIndexError.invalidPath(_) {
                conflicts.append(mutation.path)
                continue
            } catch WallpaperIndexError.invalidPropertyList {
                conflicts.append(mutation.path)
                continue
            }
            let currentFragment = try fragment(for: current)
            if currentFragment == mutation.before {
                continue
            }
            guard currentFragment == mutation.after else {
                conflicts.append(mutation.path)
                continue
            }
            let replacement = try decode(mutation.before)
            try setValue(
                replacement,
                at: mutation.path[...],
                in: &root,
                fullPath: mutation.path
            )
            restoredPaths.append(mutation.path)
        }

        let data = restoredPaths.isEmpty ? indexData : try encodeRoot(root)
        return RestoreOutcome(
            data: data,
            restoredPaths: restoredPaths,
            conflicts: conflicts
        )
    }

    private func findAerialIdleChoices(
        in value: Any,
        path: [PlistPathComponent],
        isBelowIdle: Bool,
        after: Data,
        mutations: inout [PlistMutation]
    ) throws {
        if let dictionary = value as? [String: Any] {
            if isBelowIdle,
               dictionary["Provider"] as? String == Self.aerialProvider,
               let configuration = dictionary["Configuration"] as? Data {
                let configurationPath = path + [.key("Configuration")]
                mutations.append(
                    PlistMutation(
                        path: configurationPath,
                        choiceIdentity: try choiceIdentity(for: dictionary),
                        before: try fragment(for: configuration),
                        after: after
                    )
                )
            }

            for key in dictionary.keys.sorted() {
                guard let child = dictionary[key] else { continue }
                try findAerialIdleChoices(
                    in: child,
                    path: path + [.key(key)],
                    isBelowIdle: isBelowIdle || key == "Idle",
                    after: after,
                    mutations: &mutations
                )
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                try findAerialIdleChoices(
                    in: child,
                    path: path + [.index(index)],
                    isBelowIdle: isBelowIdle,
                    after: after,
                    mutations: &mutations
                )
            }
        }
    }

    private func value(
        at path: ArraySlice<PlistPathComponent>,
        in root: Any,
        fullPath: [PlistPathComponent]
    ) throws -> Any {
        guard let component = path.first else { return root }
        switch component {
        case let .key(key):
            guard let dictionary = root as? [String: Any], let child = dictionary[key] else {
                throw WallpaperIndexError.invalidPath(fullPath)
            }
            return try value(at: path.dropFirst(), in: child, fullPath: fullPath)
        case let .index(index):
            guard let array = root as? [Any], array.indices.contains(index) else {
                throw WallpaperIndexError.invalidPath(fullPath)
            }
            return try value(at: path.dropFirst(), in: array[index], fullPath: fullPath)
        }
    }

    private func setValue(
        _ value: Any,
        at path: ArraySlice<PlistPathComponent>,
        in root: inout Any,
        fullPath: [PlistPathComponent]
    ) throws {
        guard let component = path.first else {
            root = value
            return
        }
        switch component {
        case let .key(key):
            guard var dictionary = root as? [String: Any], var child = dictionary[key] else {
                throw WallpaperIndexError.invalidPath(fullPath)
            }
            try setValue(
                value,
                at: path.dropFirst(),
                in: &child,
                fullPath: fullPath
            )
            dictionary[key] = child
            root = dictionary
        case let .index(index):
            guard var array = root as? [Any], array.indices.contains(index) else {
                throw WallpaperIndexError.invalidPath(fullPath)
            }
            var child = array[index]
            try setValue(
                value,
                at: path.dropFirst(),
                in: &child,
                fullPath: fullPath
            )
            array[index] = child
            root = array
        }
    }

    private func decode(_ data: Data) throws -> Any {
        do {
            return try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw WallpaperIndexError.invalidPropertyList
        }
    }

    private func fragment(for value: Any) throws -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: value,
                format: .binary,
                options: 0
            )
        } catch {
            throw WallpaperIndexError.invalidPropertyList
        }
    }

    private func encodeRoot(_ root: Any) throws -> Data {
        try fragment(for: root)
    }

    private func validateUniqueChoiceIdentities(_ mutations: [PlistMutation]) throws {
        for index in mutations.indices {
            guard mutations[index].path.count >= 2,
                  case .index = mutations[index].path[mutations[index].path.count - 2] else {
                continue
            }
            let choicesPath = Array(mutations[index].path.dropLast(2))
            for earlierIndex in mutations.indices where earlierIndex < index {
                guard mutations[earlierIndex].path.count >= 2,
                      case .index = mutations[earlierIndex]
                        .path[mutations[earlierIndex].path.count - 2] else {
                    continue
                }
                let earlierChoicesPath = Array(mutations[earlierIndex].path.dropLast(2))
                if earlierChoicesPath == choicesPath,
                   mutations[earlierIndex].choiceIdentity == mutations[index].choiceIdentity {
                    throw WallpaperIndexError.ambiguousChoiceIdentity(choicesPath)
                }
            }
        }
    }

    private func choiceIdentity(for value: Any) throws -> Data {
        guard var dictionary = value as? [String: Any] else {
            throw WallpaperIndexError.invalidPropertyList
        }
        dictionary.removeValue(forKey: "Configuration")
        return try fragment(for: canonicalIdentityValue(dictionary))
    }

    private func canonicalIdentityValue(_ value: Any) throws -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [Any] = ["dictionary"]
            for key in dictionary.keys.sorted() {
                guard let child = dictionary[key] else { continue }
                result.append([key, try canonicalIdentityValue(child)])
            }
            return result
        }
        if let array = value as? [Any] {
            return try ["array"] + array.map(canonicalIdentityValue)
        }
        guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else {
            throw WallpaperIndexError.invalidPropertyList
        }
        return value
    }
}
