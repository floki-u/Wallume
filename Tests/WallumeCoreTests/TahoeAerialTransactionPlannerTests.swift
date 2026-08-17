import Foundation
import XCTest
@testable import WallumeCore

final class TahoeAerialTransactionPlannerTests: XCTestCase {
    func testPlanRegistersAssetAndPreparesAerialIndexSelection() throws {
        let asset = TahoeAerialAsset(
            id: "BD000000-0000-4000-8000-000000000001",
            displayName: "Aurora",
            localVideoURL: URL(fileURLWithPath: "/tmp/Aurora.mov"),
            localThumbnailURL: URL(fileURLWithPath: "/tmp/Aurora.jpg")
        )
        let manifest = try JSONSerialization.data(
            withJSONObject: ["version": 1, "categories": [], "assets": []], options: [.sortedKeys]
        )
        let index = try targetedIndex()

        let plan = try TahoeAerialTransactionPlanner().plan(
            asset: asset,
            manifest: manifest,
            wallpaperIndex: index,
            targetDisplayID: "cg-uuid:37D8832A-2D66-02CA-B9F7-8F30A301B230"
        )

        XCTAssertFalse(plan.indexMutations.isEmpty)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: plan.registeredManifest) as? [String: Any])
        let assets = try XCTUnwrap(root["assets"] as? [[String: Any]])
        XCTAssertEqual(assets.last?["id"] as? String, asset.id)
    }

    func testPlanDoesNotRegisterAssetWhenNoAerialIndexTargetExists() throws {
        let asset = TahoeAerialAsset(
            id: "BD000000-0000-4000-8000-000000000001",
            displayName: "Aurora",
            localVideoURL: URL(fileURLWithPath: "/tmp/Aurora.mov"),
            localThumbnailURL: URL(fileURLWithPath: "/tmp/Aurora.jpg")
        )
        let manifest = try JSONSerialization.data(
            withJSONObject: ["version": 1, "categories": [], "assets": []], options: [.sortedKeys]
        )
        let noAerialIndex = try PropertyListSerialization.data(
            fromPropertyList: ["Idle": ["Provider": "default"]], format: .binary, options: 0
        )

        XCTAssertThrowsError(try TahoeAerialTransactionPlanner().plan(
            asset: asset,
            manifest: manifest,
            wallpaperIndex: noAerialIndex,
            targetDisplayID: "cg-uuid:37D8832A-2D66-02CA-B9F7-8F30A301B230"
        ))
    }

    private func targetedIndex() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Displays": [
                    "37D8832A-2D66-02CA-B9F7-8F30A301B230": [
                        "Idle": ["Content": ["Choices": [["Provider": "default"]]], "LastSet": Date()],
                    ],
                ],
            ],
            format: .binary,
            options: 0
        )
    }
}
