import Foundation
import XCTest
@testable import WallumeCore

final class TahoeAerialCatalogTests: XCTestCase {
    func testRegisterPreservesExistingAssetsAndAddsLocalVideoAsset() throws {
        let catalog = TahoeAerialCatalog()
        let original = fixtureManifest()
        let asset = TahoeAerialAsset(
            id: "BD000000-0000-4000-8000-000000000001",
            displayName: "Aurora",
            localVideoURL: URL(fileURLWithPath: "/Users/tester/Wallume/Aurora.mov"),
            localThumbnailURL: URL(fileURLWithPath: "/Users/tester/Wallume/Aurora.jpg")
        )

        let registered = try catalog.register(asset, in: original)
        let root = try decode(registered)
        let assets = try XCTUnwrap(root["assets"] as? [[String: Any]])

        XCTAssertEqual(assets.count, 2)
        XCTAssertEqual(assets[0]["id"] as? String, "APPLE-ONE")
        XCTAssertEqual(assets[1]["id"] as? String, asset.id)
        XCTAssertEqual(assets[1]["accessibilityLabel"] as? String, "Aurora")
        XCTAssertEqual(assets[1]["url-4K-SDR-240FPS"] as? String, asset.localVideoURL.absoluteString)
        XCTAssertEqual(assets[1]["previewImage"] as? String, asset.localThumbnailURL?.absoluteString)
        XCTAssertEqual(assets[1]["categories"] as? [String], [TahoeAerialAsset.wallumeCategoryID])
        XCTAssertEqual(assets[1]["includeInShuffle"] as? Bool, true)
        let categories = try XCTUnwrap(root["categories"] as? [[String: Any]])
        XCTAssertEqual(categories.last?["id"] as? String, TahoeAerialAsset.wallumeCategoryID)
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertEqual(root["unknownSystemField"] as? String, "retain-me")
    }

    func testRegisterRejectsDuplicateAssetIDWithoutChangingManifest() throws {
        let catalog = TahoeAerialCatalog()
        let original = fixtureManifest()
        let asset = TahoeAerialAsset(
            id: "APPLE-ONE",
            displayName: "Duplicate",
            localVideoURL: URL(fileURLWithPath: "/tmp/Duplicate.mov"),
            localThumbnailURL: URL(fileURLWithPath: "/tmp/Duplicate.jpg")
        )

        XCTAssertThrowsError(try catalog.register(asset, in: original)) { error in
            XCTAssertEqual(error as? TahoeAerialCatalogError, .assetAlreadyExists(asset.id))
        }
    }

    func testRemoveRestoresManifestWithoutTouchingForeignAssets() throws {
        let catalog = TahoeAerialCatalog()
        let asset = TahoeAerialAsset(
            id: "BD000000-0000-4000-8000-000000000001",
            displayName: "Aurora",
            localVideoURL: URL(fileURLWithPath: "/tmp/Aurora.mov"),
            localThumbnailURL: URL(fileURLWithPath: "/tmp/Aurora.jpg")
        )
        let registered = try catalog.register(asset, in: fixtureManifest())
        let withForeignAsset = try appendForeignAsset(to: registered)

        let restored = try catalog.remove(asset, from: withForeignAsset)
        let assets = try XCTUnwrap(try decode(restored)["assets"] as? [[String: Any]])

        XCTAssertEqual(assets.map { $0["id"] as? String }, ["APPLE-ONE", "FOREIGN-ASSET"])
    }

    func testRemoveRejectsAnExternallyChangedWallumeAsset() throws {
        let catalog = TahoeAerialCatalog()
        let asset = TahoeAerialAsset(
            id: "BD000000-0000-4000-8000-000000000001",
            displayName: "Aurora",
            localVideoURL: URL(fileURLWithPath: "/tmp/Aurora.mov"),
            localThumbnailURL: URL(fileURLWithPath: "/tmp/Aurora.jpg")
        )
        let registered = try catalog.register(asset, in: fixtureManifest())
        let tampered = try changeAssetName(in: registered, id: asset.id, to: "Changed elsewhere")

        XCTAssertThrowsError(try catalog.remove(asset, from: tampered)) { error in
            XCTAssertEqual(error as? TahoeAerialCatalogError, .assetChangedExternally(asset.id))
        }
    }

    private func fixtureManifest() -> Data {
        try! JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "unknownSystemField": "retain-me",
                "categories": [],
                "assets": [[
                    "id": "APPLE-ONE",
                    "accessibilityLabel": "Apple One",
                    "includeInShuffle": true,
                ]],
            ],
            options: [.sortedKeys]
        )
    }

    private func appendForeignAsset(to data: Data) throws -> Data {
        var root = try decode(data)
        var assets = try XCTUnwrap(root["assets"] as? [[String: Any]])
        assets.append(["id": "FOREIGN-ASSET", "accessibilityLabel": "Other App"])
        root["assets"] = assets
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func changeAssetName(in data: Data, id: String, to name: String) throws -> Data {
        var root = try decode(data)
        var assets = try XCTUnwrap(root["assets"] as? [[String: Any]])
        let index = try XCTUnwrap(assets.firstIndex { $0["id"] as? String == id })
        assets[index]["accessibilityLabel"] = name
        root["assets"] = assets
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
