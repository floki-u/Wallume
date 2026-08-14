import Foundation

/// A user-owned Aerial entry for macOS 26's wallpaper cache.
///
/// This deliberately describes only a local video. It never writes into `/System`, replaces an
/// Apple-owned asset, or claims that the undocumented format is a public macOS contract.
public struct TahoeAerialAsset: Equatable, Sendable {
    public static let wallumeCategoryID = "A6A93D98-3346-4E7F-9FA8-43BA1A7C1F12"
    public static let wallumeSubcategoryID = "EDB51A7A-3031-4CE2-93A4-A7EE7C49BA23"

    public let id: String
    public let displayName: String
    public let localVideoURL: URL
    public let localThumbnailURL: URL?

    public init(id: String, displayName: String, localVideoURL: URL, localThumbnailURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.localVideoURL = localVideoURL
        self.localThumbnailURL = localThumbnailURL
    }
}

public enum TahoeAerialCatalogError: Error, Equatable, Sendable {
    case malformedManifest
    case invalidAsset
    case assetAlreadyExists(String)
    case assetMissing(String)
    case assetChangedExternally(String)
}

/// Performs narrow, reversible edits to the user-level Aerial manifest.
///
/// A transaction must still preserve the entire original manifest before publishing a returned
/// document. The exact comparison in `remove` prevents Wallume from deleting an entry another
/// tool has modified after registration.
public struct TahoeAerialCatalog: Sendable {
    public init() {}

    public func register(_ asset: TahoeAerialAsset, in manifest: Data) throws -> Data {
        try validate(asset)
        var root = try decodeRoot(manifest)
        var assets = try assetArray(from: root)
        guard !assets.contains(where: { $0["id"] as? String == asset.id }) else {
            throw TahoeAerialCatalogError.assetAlreadyExists(asset.id)
        }
        assets.append(dictionary(for: asset))
        root["assets"] = assets
        root["categories"] = try categoriesAfterRegistering(asset, in: root)
        return try encode(root)
    }

    public func remove(_ asset: TahoeAerialAsset, from manifest: Data) throws -> Data {
        try validate(asset)
        var root = try decodeRoot(manifest)
        var assets = try assetArray(from: root)
        guard let index = assets.firstIndex(where: { $0["id"] as? String == asset.id }) else {
            throw TahoeAerialCatalogError.assetMissing(asset.id)
        }
        guard try encode(assets[index]) == encode(dictionary(for: asset)) else {
            throw TahoeAerialCatalogError.assetChangedExternally(asset.id)
        }
        assets.remove(at: index)
        root["assets"] = assets
        root["categories"] = try categoriesAfterRemoving(asset, remainingAssets: assets, in: root)
        return try encode(root)
    }

    private func validate(_ asset: TahoeAerialAsset) throws {
        guard !asset.id.isEmpty,
              !asset.id.contains("/"),
              !asset.id.contains(".."),
              !asset.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              asset.localVideoURL.isFileURL,
              asset.localThumbnailURL?.isFileURL == true else {
            throw TahoeAerialCatalogError.invalidAsset
        }
    }

    private func dictionary(for asset: TahoeAerialAsset) -> [String: Any] {
        [
            "id": asset.id,
            "accessibilityLabel": asset.displayName,
            "localizedNameKey": asset.displayName,
            "shotID": "WALLUME_CUSTOM",
            "includeInShuffle": true,
            "preferredOrder": 0,
            "showInTopLevel": true,
            "pointsOfInterest": ["0": "WALLUME_0"],
            "categories": [SelfCategory.id],
            "subcategories": [SelfCategory.subcategoryID],
            "url-4K-SDR-240FPS": asset.localVideoURL.absoluteString,
            "previewImage": asset.localThumbnailURL!.absoluteString,
        ]
    }

    private enum SelfCategory {
        static let id = TahoeAerialAsset.wallumeCategoryID
        static let subcategoryID = TahoeAerialAsset.wallumeSubcategoryID
    }

    private func categoriesAfterRegistering(_ asset: TahoeAerialAsset, in root: [String: Any]) throws -> [[String: Any]] {
        var categories = try categoryArray(from: root)
        let category = categoryDictionary(representative: asset)
        if let index = categories.firstIndex(where: { $0["id"] as? String == SelfCategory.id }) {
            categories[index] = category
        } else {
            categories.append(category)
        }
        return categories
    }

    private func categoriesAfterRemoving(
        _ asset: TahoeAerialAsset,
        remainingAssets: [[String: Any]],
        in root: [String: Any]
    ) throws -> [[String: Any]] {
        var categories = try categoryArray(from: root)
        let ownedAssets = remainingAssets.filter {
            ($0["categories"] as? [String])?.contains(SelfCategory.id) == true
        }
        guard let representative = ownedAssets.last else {
            categories.removeAll { $0["id"] as? String == SelfCategory.id }
            return categories
        }
        guard let id = representative["id"] as? String,
              let name = representative["accessibilityLabel"] as? String,
              let video = representative["url-4K-SDR-240FPS"] as? String,
              let thumbnail = representative["previewImage"] as? String,
              let videoURL = URL(string: video),
              let thumbnailURL = URL(string: thumbnail) else {
            throw TahoeAerialCatalogError.malformedManifest
        }
        let replacement = TahoeAerialAsset(
            id: id,
            displayName: name,
            localVideoURL: videoURL,
            localThumbnailURL: thumbnailURL
        )
        let category = categoryDictionary(representative: replacement)
        if let index = categories.firstIndex(where: { $0["id"] as? String == SelfCategory.id }) {
            categories[index] = category
        } else {
            categories.append(category)
        }
        return categories
    }

    private func categoryDictionary(representative asset: TahoeAerialAsset) -> [String: Any] {
        let thumbnail = asset.localThumbnailURL!.absoluteString
        return [
            "id": SelfCategory.id,
            "localizedNameKey": "Wallume",
            "localizedDescriptionKey": "Wallume custom dynamic wallpapers",
            "preferredOrder": 999,
            "representativeAssetID": asset.id,
            "previewImage": thumbnail,
            "subcategories": [[
                "id": SelfCategory.subcategoryID,
                "localizedNameKey": "Wallume",
                "localizedDescriptionKey": "Wallume custom dynamic wallpapers",
                "preferredOrder": 0,
                "previewImage": thumbnail,
                "representativeAssetID": asset.id,
            ]],
        ]
    }

    private func decodeRoot(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TahoeAerialCatalogError.malformedManifest
        }
        return root
    }

    private func assetArray(from root: [String: Any]) throws -> [[String: Any]] {
        guard let assets = root["assets"] as? [[String: Any]] else {
            throw TahoeAerialCatalogError.malformedManifest
        }
        return assets
    }

    private func categoryArray(from root: [String: Any]) throws -> [[String: Any]] {
        guard let categories = root["categories"] as? [[String: Any]] else {
            throw TahoeAerialCatalogError.malformedManifest
        }
        return categories
    }

    private func encode(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw TahoeAerialCatalogError.malformedManifest
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
