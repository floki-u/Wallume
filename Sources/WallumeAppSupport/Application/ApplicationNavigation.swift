import Observation
import WallumeCore

@Observable
public final class ApplicationNavigation {
    public var selection: WallumeFeatureID
    public private(set) var preferredAssignmentDisplayID: DisplayID?

    public init(selection: WallumeFeatureID = .gallery) {
        self.selection = selection
    }

    public func open(_ feature: WallumeFeatureID) {
        selection = feature
    }

    public func openGalleryForWallpaper(displayID: DisplayID) {
        preferredAssignmentDisplayID = displayID
        selection = .gallery
    }

    public func clearWallpaperTarget() {
        preferredAssignmentDisplayID = nil
    }
}
