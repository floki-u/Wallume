import Foundation

public struct AtomicJSONStore: Sendable {
    private let files: any FileStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(files: any FileStore) {
        self.files = files
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try files.writeAtomically(encoder.encode(value), to: url)
    }

    public func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try decoder.decode(type, from: files.read(url))
    }
}
