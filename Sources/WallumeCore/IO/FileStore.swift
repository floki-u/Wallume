import Foundation

public protocol FileStore: Sendable {
    func exists(_ url: URL) -> Bool
    func read(_ url: URL) throws -> Data
    func contents(_ directory: URL) throws -> [URL]
    func createDirectory(_ url: URL) throws
    func writeAtomically(_ data: Data, to target: URL) throws
    func copy(_ source: URL, to destination: URL) throws
    func replace(_ target: URL, with preparedFile: URL) throws
    func remove(_ url: URL) throws
}

public struct LocalFileStore: FileStore {
    private var manager: FileManager { .default }

    public init() {}

    public func exists(_ url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    public func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func contents(_ directory: URL) throws -> [URL] {
        try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    public func createDirectory(_ url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func copy(_ source: URL, to destination: URL) throws {
        try createDirectory(destination.deletingLastPathComponent())
        try manager.copyItem(at: source, to: destination)
    }

    public func replace(_ target: URL, with preparedFile: URL) throws {
        if exists(target) {
            _ = try manager.replaceItemAt(target, withItemAt: preparedFile)
        } else {
            try manager.moveItem(at: preparedFile, to: target)
        }
    }

    public func remove(_ url: URL) throws {
        if exists(url) {
            try manager.removeItem(at: url)
        }
    }

    public func writeAtomically(_ data: Data, to target: URL) throws {
        try createDirectory(target.deletingLastPathComponent())
        let temporary = target.appendingPathExtension("tmp")
        try remove(temporary)

        guard manager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var handle: FileHandle?
        do {
            handle = try FileHandle(forWritingTo: temporary)
            try handle?.write(contentsOf: data)
            try handle?.synchronize()
            try handle?.close()
            handle = nil
            try replace(target, with: temporary)
        } catch {
            try? handle?.close()
            try? remove(temporary)
            throw error
        }
    }
}
