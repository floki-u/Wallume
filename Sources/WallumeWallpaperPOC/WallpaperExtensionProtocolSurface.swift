import Foundation

/// The private XPC selector surface observed in an external reference implementation.
///
/// No object in this package adopts these protocols. They are declarations for build-time
/// review only and cannot register an extension or create a WallpaperAgent connection.
@objc public protocol WallpaperExtensionHostToProviderProtocol: NSObjectProtocol {
    func acquire(withId id: Any?, request: Any?, reply: @escaping (Any?, NSError?) -> Void)
    func update(withId id: Any?, request: Any?, reply: @escaping (NSError?) -> Void)
    func invalidate(withId id: Any?, reply: @escaping (NSError?) -> Void)
    func snapshot(withId id: Any?, reply: @escaping (Any?, NSError?) -> Void)
    func provideSettingsViewModels(withContentTypes contentTypes: Any?, reply: @escaping (Any?, NSError?) -> Void)
}

@objc public protocol WallpaperExtensionProviderToHostProtocol: NSObjectProtocol {
    func invalidateSnapshots(withReply reply: @escaping (NSError?) -> Void)
    func updateSettingsViewModels(_ models: Any?, reply: @escaping (NSError?) -> Void)
}

public enum WallpaperExtensionProtocolSurface {
    public static let hostToProviderSelectors = [
        "acquireWithId:request:reply:",
        "updateWithId:request:reply:",
        "invalidateWithId:reply:",
        "snapshotWithId:reply:",
        "provideSettingsViewModelsWithContentTypes:reply:",
    ]

    public static let providerToHostSelectors = [
        "invalidateSnapshotsWithReply:",
        "updateSettingsViewModels:reply:",
    ]
}
