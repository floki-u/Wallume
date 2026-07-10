import Foundation

public enum MacOSGeneration: Equatable, Sendable {
    case sonoma
    case sequoia
    case tahoe
    case unsupported(Int)

    public init(version: OperatingSystemVersion) {
        switch version.majorVersion {
        case 14: self = .sonoma
        case 15: self = .sequoia
        case 26: self = .tahoe
        default: self = .unsupported(version.majorVersion)
        }
    }

    public var permitsWrites: Bool {
        switch self {
        case .sonoma, .sequoia, .tahoe: true
        case .unsupported: false
        }
    }
}
