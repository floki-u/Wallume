import Foundation

/// A reversible replacement of one complete Tahoe lock-screen (`Idle`) entry.
///
/// Tahoe stores different providers (Aerial, Sequoia, Macintosh, screen saver and default) at
/// these locations.  Replacing only the configuration of pre-existing Aerial entries leaves the
/// active non-Aerial locations untouched, which looks successful in an app while doing nothing at
/// the lock screen.  This mutation deliberately snapshots the entire `Idle` value instead.
public struct TahoeIndexMutation: Codable, Equatable, Sendable {
    public let path: [PlistPathComponent]
    public let before: Data
    public let after: Data

    public init(path: [PlistPathComponent], before: Data, after: Data) {
        self.path = path
        self.before = before
        self.after = after
    }
}

public enum TahoeWallpaperIndexError: Error, Equatable, Sendable {
    case invalidPropertyList
    case noLockScreenTargets
    case staleValue([PlistPathComponent])
    case invalidPath([PlistPathComponent])
}

public struct TahoeWallpaperIndexPatcher: Sendable {
    private static let aerialProvider = "com.apple.wallpaper.choice.aerials"

    public init() {}

    /// Plans the selected display's direct and per-space lock-screen overrides. It must never
    /// write SystemDefault or another display: those values drive the System Settings multi-
    /// display model and broad replacement collapses that model into one global setting.
    public func plan(indexData: Data, aerialID: String, targetDisplayID: String) throws -> [TahoeIndexMutation] {
        let root = try decode(indexData)
        guard let rootDictionary = root as? [String: Any] else {
            throw TahoeWallpaperIndexError.invalidPropertyList
        }
        let displayID = try normalizedDisplayID(targetDisplayID)
        let replacementChoice: [String: Any] = [
            "Provider": Self.aerialProvider,
            "Files": [Any](),
            "Configuration": try PropertyListSerialization.data(
                fromPropertyList: ["assetID": aerialID],
                format: .binary,
                options: 0
            ),
        ]
        var mutations: [TahoeIndexMutation] = []
        try findSelectedDisplayIdleEntries(
            in: root,
            path: [],
            selectedDisplayID: displayID,
            replacementChoice: replacementChoice,
            mutations: &mutations
        )
        // When System Settings is in its own "automatic / all spaces" mode it deliberately
        // removes the per-display and per-space trees. There is then no display choice to
        // preserve. Mutate only the pre-existing global linked choices, never synthesize a
        // global mode while display-specific choices exist.
        if mutations.isEmpty {
            try findGlobalLinkedEntries(
                in: rootDictionary,
                replacementChoice: replacementChoice,
                mutations: &mutations
            )
        }
        guard !mutations.isEmpty else { throw TahoeWallpaperIndexError.noLockScreenTargets }
        return mutations
    }

    public func apply(_ mutations: [TahoeIndexMutation], to indexData: Data) throws -> Data {
        var root = try decode(indexData)
        for mutation in mutations {
            let current = try value(at: mutation.path[...], in: root, fullPath: mutation.path)
            guard try equivalent(current, decode(mutation.before)) else {
                throw TahoeWallpaperIndexError.staleValue(mutation.path)
            }
            try setValue(try decode(mutation.after), at: mutation.path[...], in: &root, fullPath: mutation.path)
        }
        return try fragment(for: root)
    }

    public func restore(_ mutations: [TahoeIndexMutation], in indexData: Data) throws -> RestoreOutcome {
        var root = try decode(indexData)
        var restored: [[PlistPathComponent]] = []
        var conflicts: [[PlistPathComponent]] = []

        for mutation in mutations {
            let current: Any
            do {
                current = try value(at: mutation.path[...], in: root, fullPath: mutation.path)
            } catch {
                conflicts.append(mutation.path)
                continue
            }
            if try equivalent(current, decode(mutation.before)) { continue }
            if try equivalent(current, decode(mutation.after)) {
                try setValue(try decode(mutation.before), at: mutation.path[...], in: &root, fullPath: mutation.path)
                restored.append(mutation.path)
                continue
            }
            // WallpaperAgent updates LastSet/LastUse after it observes an Index.plist change.
            // Those timestamps are system-owned noise, not a competing choice.  Old Wallume
            // journals stored the complete Idle value, so recover their original Choices when
            // (and only when) the current choices still equal Wallume's post-write choice.
            if let repaired = try restoringChoicesOnly(
                current: current,
                before: decode(mutation.before),
                after: decode(mutation.after)
            ) {
                try setValue(repaired, at: mutation.path[...], in: &root, fullPath: mutation.path)
                restored.append(mutation.path)
            } else {
                conflicts.append(mutation.path)
            }
        }
        return RestoreOutcome(
            data: restored.isEmpty ? indexData : try fragment(for: root),
            restoredPaths: restored,
            conflicts: conflicts
        )
    }

    private func findSelectedDisplayIdleEntries(
        in value: Any,
        path: [PlistPathComponent],
        selectedDisplayID: String,
        replacementChoice: [String: Any],
        mutations: inout [TahoeIndexMutation]
    ) throws {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                guard let child = dictionary[key] else { continue }
                let childPath = path + [.key(key)]
                if key == "Idle",
                   isSelectedDisplayIdlePath(path, selectedDisplayID: selectedDisplayID),
                   let idle = child as? [String: Any],
                   let replaced = try replacingChoices(in: idle, with: replacementChoice) {
                    mutations.append(TahoeIndexMutation(
                        path: childPath,
                        before: try fragment(for: idle),
                        after: try fragment(for: replaced)
                    ))
                } else {
                    try findSelectedDisplayIdleEntries(
                        in: child,
                        path: childPath,
                        selectedDisplayID: selectedDisplayID,
                        replacementChoice: replacementChoice,
                        mutations: &mutations
                    )
                }
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                try findSelectedDisplayIdleEntries(
                    in: child,
                    path: path + [.index(index)],
                    selectedDisplayID: selectedDisplayID,
                    replacementChoice: replacementChoice,
                    mutations: &mutations
                )
            }
        }
    }

    private func findGlobalLinkedEntries(
        in root: [String: Any],
        replacementChoice: [String: Any],
        mutations: inout [TahoeIndexMutation]
    ) throws {
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard let entry = root[key] as? [String: Any],
                  let linked = entry["Linked"] as? [String: Any],
                  let replaced = try replacingChoices(in: linked, with: replacementChoice) else {
                continue
            }
            mutations.append(TahoeIndexMutation(
                path: [.key(key), .key("Linked")],
                before: try fragment(for: linked),
                after: try fragment(for: replaced)
            ))
        }
    }

    private func normalizedDisplayID(_ raw: String) throws -> String {
        let prefix = "cg-uuid:"
        let value = raw.lowercased().hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
        guard UUID(uuidString: value) != nil else { throw TahoeWallpaperIndexError.noLockScreenTargets }
        return value.uppercased()
    }

    private func isSelectedDisplayIdlePath(_ path: [PlistPathComponent], selectedDisplayID: String) -> Bool {
        let keys = path.compactMap { component -> String? in
            guard case let .key(value) = component else { return nil }
            return value
        }
        // Displays/<display>/Idle
        if keys == ["Displays", selectedDisplayID] { return true }
        // Spaces/<space>/Displays/<display>/Idle. The empty key is Tahoe's all-spaces entry;
        // UUID keys are individual desktop spaces. Updating every space only for this display
        // reaches the current lock-screen context without flattening other displays' choices.
        return keys.count == 4
            && keys[0] == "Spaces"
            && keys[2] == "Displays"
            && keys[3] == selectedDisplayID
    }

    private func replacingChoices(in idle: [String: Any], with choice: [String: Any]) throws -> [String: Any]? {
        guard var content = idle["Content"] as? [String: Any], content["Choices"] as? [Any] != nil else {
            return nil
        }
        content["Choices"] = [choice]
        var replacement = idle
        replacement["Content"] = content
        return replacement
    }

    private func restoringChoicesOnly(current: Any, before: Any, after: Any) throws -> Any? {
        guard var currentIdle = current as? [String: Any],
              let beforeIdle = before as? [String: Any],
              let afterIdle = after as? [String: Any],
              var currentContent = currentIdle["Content"] as? [String: Any],
              let beforeContent = beforeIdle["Content"] as? [String: Any],
              let afterContent = afterIdle["Content"] as? [String: Any],
              let currentChoices = currentContent["Choices"],
              let beforeChoices = beforeContent["Choices"],
              let afterChoices = afterContent["Choices"],
              try equivalent(currentChoices, afterChoices)
        else { return nil }
        currentContent["Choices"] = beforeChoices
        currentIdle["Content"] = currentContent
        return currentIdle
    }

    private func decode(_ data: Data) throws -> Any {
        do { return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw TahoeWallpaperIndexError.invalidPropertyList }
    }

    private func fragment(for value: Any) throws -> Data {
        do { return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) }
        catch { throw TahoeWallpaperIndexError.invalidPropertyList }
    }

    private func equivalent(_ lhs: Any, _ rhs: Any) throws -> Bool {
        if let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any] {
            guard lhs.count == rhs.count else { return false }
            return try lhs.allSatisfy { key, value in
                guard let other = rhs[key] else { return false }
                return try equivalent(value, other)
            }
        }
        if let lhs = lhs as? [Any], let rhs = rhs as? [Any] {
            guard lhs.count == rhs.count else { return false }
            return try zip(lhs, rhs).allSatisfy { try equivalent($0, $1) }
        }
        if let lhs = lhs as? Data, let rhs = rhs as? Data { return lhs == rhs }
        if let lhs = lhs as? Date, let rhs = rhs as? Date { return lhs == rhs }
        guard let lhs = lhs as? NSObject else { throw TahoeWallpaperIndexError.invalidPropertyList }
        return lhs.isEqual(rhs)
    }

    private func value(at path: ArraySlice<PlistPathComponent>, in root: Any, fullPath: [PlistPathComponent]) throws -> Any {
        guard let component = path.first else { return root }
        switch component {
        case let .key(key):
            guard let dictionary = root as? [String: Any], let child = dictionary[key] else {
                throw TahoeWallpaperIndexError.invalidPath(fullPath)
            }
            return try value(at: path.dropFirst(), in: child, fullPath: fullPath)
        case let .index(index):
            guard let array = root as? [Any], array.indices.contains(index) else {
                throw TahoeWallpaperIndexError.invalidPath(fullPath)
            }
            return try value(at: path.dropFirst(), in: array[index], fullPath: fullPath)
        }
    }

    private func setValue(_ value: Any, at path: ArraySlice<PlistPathComponent>, in root: inout Any, fullPath: [PlistPathComponent]) throws {
        guard let component = path.first else { root = value; return }
        switch component {
        case let .key(key):
            guard var dictionary = root as? [String: Any], var child = dictionary[key] else {
                throw TahoeWallpaperIndexError.invalidPath(fullPath)
            }
            try setValue(value, at: path.dropFirst(), in: &child, fullPath: fullPath)
            dictionary[key] = child
            root = dictionary
        case let .index(index):
            guard var array = root as? [Any], array.indices.contains(index) else {
                throw TahoeWallpaperIndexError.invalidPath(fullPath)
            }
            var child = array[index]
            try setValue(value, at: path.dropFirst(), in: &child, fullPath: fullPath)
            array[index] = child
            root = array
        }
    }
}
