import Foundation

/// Fully validated, side-effect-free preparation for a Tahoe custom Aerial install.
///
/// The executor publishes these three changes only after it has copied media and journaled the
/// original state. Keeping planning pure ensures malformed manifests or stale wallpaper indexes
/// fail before any user-level system file is touched.
public struct TahoeAerialTransactionPlan: Sendable {
    public let asset: TahoeAerialAsset
    public let registeredManifest: Data
    public let indexMutations: [TahoeIndexMutation]

    public init(
        asset: TahoeAerialAsset,
        registeredManifest: Data,
        indexMutations: [TahoeIndexMutation]
    ) {
        self.asset = asset
        self.registeredManifest = registeredManifest
        self.indexMutations = indexMutations
    }
}

public struct TahoeAerialTransactionPlanner: Sendable {
    private let catalog: TahoeAerialCatalog
    private let indexPatcher: TahoeWallpaperIndexPatcher

    public init(
        catalog: TahoeAerialCatalog = TahoeAerialCatalog(),
        indexPatcher: TahoeWallpaperIndexPatcher = TahoeWallpaperIndexPatcher()
    ) {
        self.catalog = catalog
        self.indexPatcher = indexPatcher
    }

    public func plan(
        asset: TahoeAerialAsset,
        manifest: Data,
        wallpaperIndex: Data,
        targetDisplayID: String
    ) throws -> TahoeAerialTransactionPlan {
        TahoeAerialTransactionPlan(
            asset: asset,
            registeredManifest: try catalog.register(asset, in: manifest),
            indexMutations: try indexPatcher.plan(
                indexData: wallpaperIndex,
                aerialID: asset.id,
                targetDisplayID: targetDisplayID
            )
        )
    }
}
