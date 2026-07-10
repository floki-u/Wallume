import Darwin
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
    private let replaceItem: @Sendable (URL, URL) throws -> Void
    private let synchronizeDirectory: @Sendable (URL) throws -> Void
    private var manager: FileManager { .default }

    public init() {
        replaceItem = Self.renameItem
        synchronizeDirectory = Self.synchronizeDirectoryEntry
    }

    init(
        replaceItem: @escaping @Sendable (URL, URL) throws -> Void,
        synchronizeDirectory: @escaping @Sendable (URL) throws -> Void
    ) {
        self.replaceItem = replaceItem
        self.synchronizeDirectory = synchronizeDirectory
    }

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
        let sourceHandle = try FileHandle(forReadingFrom: source)
        var sourceIsClosed = false
        defer {
            if !sourceIsClosed {
                try? sourceHandle.close()
            }
        }

        try installAtomically(to: destination) { destinationHandle in
            while let chunk = try sourceHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try destinationHandle.write(contentsOf: chunk)
            }
            try sourceHandle.close()
            sourceIsClosed = true
        }
    }

    public func replace(_ target: URL, with preparedFile: URL) throws {
        try replaceItem(preparedFile, target)
        try synchronizeDirectory(target.deletingLastPathComponent())
    }

    public func remove(_ url: URL) throws {
        if exists(url) {
            try manager.removeItem(at: url)
        }
    }

    public func writeAtomically(_ data: Data, to target: URL) throws {
        try installAtomically(to: target) { handle in
            try handle.write(contentsOf: data)
        }
    }

    private func installAtomically(
        to target: URL,
        writing contents: (FileHandle) throws -> Void
    ) throws {
        try createDirectory(target.deletingLastPathComponent())
        let (temporary, handle) = try makeTemporaryFile(nextTo: target)
        var handleIsClosed = false
        defer {
            if !handleIsClosed {
                try? handle.close()
            }
            try? remove(temporary)
        }

        try contents(handle)
        try handle.synchronize()
        try handle.close()
        handleIsClosed = true
        try replace(target, with: temporary)
    }

    private func makeTemporaryFile(nextTo target: URL) throws -> (URL, FileHandle) {
        let directory = target.deletingLastPathComponent()
        let prefix = ".\(target.lastPathComponent).wallume.tmp.XXXXXX"
        var template = Array(directory.appending(path: prefix).path.utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress)
        }
        guard descriptor >= 0 else {
            throw Self.posixError()
        }

        let path = String(
            decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let url = URL(fileURLWithPath: path)
        return (url, FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }

    private static func renameItem(_ source: URL, _ destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw posixError()
        }
    }

    private static func synchronizeDirectoryEntry(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw posixError()
        }

        if Darwin.fsync(descriptor) != 0 {
            let error = posixError()
            _ = Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            throw posixError()
        }
    }

    private static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
