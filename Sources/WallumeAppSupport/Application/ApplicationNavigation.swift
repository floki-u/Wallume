import Observation

@Observable
public final class ApplicationNavigation {
    public var selection: WallumeFeatureID

    public init(selection: WallumeFeatureID = .gallery) {
        self.selection = selection
    }

    public func open(_ feature: WallumeFeatureID) {
        selection = feature
    }
}
