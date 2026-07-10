import CryptoKit
import Foundation

public protocol Digesting: Sendable {
    func sha256(of url: URL) throws -> String
}

public struct SHA256Digester: Digesting {
    public init() {}

    public func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
