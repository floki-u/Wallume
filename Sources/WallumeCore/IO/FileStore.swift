import Darwin
import Foundation

public enum AtomicFileStoreError: Error, Equatable {
    case exchangeRecoveryFailed(URL)
    case unsafeReplacementTarget(URL)
}

public struct FileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let isDirectory: Bool
    public let isRegularFile: Bool
}

public protocol FileStore: Sendable {
    func exists(_ url: URL) -> Bool
    func read(_ url: URL) throws -> Data
    func contents(_ directory: URL) throws -> [URL]
    func createDirectory(_ url: URL) throws
    func createPrivateDirectory(_ url: URL) throws
    func identity(of url: URL) throws -> FileIdentity
    func hasNoSymlinkComponents(_ url: URL) throws -> Bool
    func removeDurably(_ url: URL, ifIdentityMatches identity: FileIdentity) throws -> Bool
    func writeAtomically(_ data: Data, to target: URL) throws
    func writeExclusively(_ data: Data, to target: URL) throws
    func copy(_ source: URL, to destination: URL) throws
    func copyExclusively(_ source: URL, to destination: URL) throws
    func replace(_ target: URL, with preparedFile: URL) throws
    func exchange(_ target: URL, with preparedFile: URL) throws
    func installExclusively(_ target: URL, from preparedFile: URL) throws
    func remove(_ url: URL) throws
}

public struct LocalFileStore: FileStore {
    private let synchronizeDirectory: @Sendable (URL) throws -> Void
    private let beforeAtomicReplacement: @Sendable (URL, URL) throws -> Void
    private var manager: FileManager { .default }

    public init() {
        synchronizeDirectory = Self.synchronizeDirectoryEntry
        beforeAtomicReplacement = { _, _ in }
    }

    init(
        synchronizeDirectory: @escaping @Sendable (URL) throws -> Void,
        beforeAtomicReplacement: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in }
    ) {
        self.synchronizeDirectory = synchronizeDirectory
        self.beforeAtomicReplacement = beforeAtomicReplacement
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

    public func createPrivateDirectory(_ url: URL) throws {
        guard let parent = try Self.openDirectoryNoFollow(url.deletingLastPathComponent()) else {
            throw Self.posixError(ELOOP)
        }
        defer { _ = Darwin.close(parent) }
        let created = url.lastPathComponent.withCString { Darwin.mkdirat(parent, $0, 0o700) }
        if created != 0, errno != EEXIST { throw Self.posixError() }
        var info = stat()
        let status = url.lastPathComponent.withCString {
            Darwin.fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o700 else { throw Self.posixError(EACCES) }
        if created == 0, Darwin.fsync(parent) != 0 { throw Self.posixError() }
    }

    public func identity(of url: URL) throws -> FileIdentity {
        guard let parent = try Self.openDirectoryNoFollow(url.deletingLastPathComponent()) else {
            throw Self.posixError(ELOOP)
        }
        defer { _ = Darwin.close(parent) }
        var info = stat()
        let status = url.lastPathComponent.withCString {
            Darwin.fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { throw Self.posixError() }
        return FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
            isRegularFile: (info.st_mode & S_IFMT) == S_IFREG
        )
    }

    public func hasNoSymlinkComponents(_ url: URL) throws -> Bool {
        let components = url.path.split(separator: "/").map(String.init)
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { _ = Darwin.close(descriptor) }

        for (index, component) in components.enumerated() {
            var info = stat()
            let status = component.withCString {
                Darwin.fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            if status != 0, errno == ENOENT { return true }
            guard status == 0 else { throw Self.posixError() }
            if (info.st_mode & S_IFMT) == S_IFLNK { return false }
            guard index < components.count - 1 else { return true }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
            let next = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                if errno == ELOOP { return false }
                throw Self.posixError()
            }
            _ = Darwin.close(descriptor)
            descriptor = next
        }
        return true
    }

    public func removeDurably(
        _ url: URL,
        ifIdentityMatches identity: FileIdentity
    ) throws -> Bool {
        // macOS has no compare-inode-and-unlink syscall. The private 0700 directory,
        // process-wide flock, no-follow descriptor traversal, and immediate fstatat /
        // unlinkat sequence cover Wallume concurrency, crashes, and ordinary external
        // rewrites. They do not claim to defeat an active same-UID attacker that wins
        // the final syscall window by precisely replacing this directory entry.
        guard let descriptor = try Self.openDirectoryNoFollow(
            url.deletingLastPathComponent()
        ) else { return false }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        let status = url.lastPathComponent.withCString {
            Darwin.fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0, errno == ENOENT { return false }
        guard status == 0 else { throw Self.posixError() }
        let observed = FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
            isRegularFile: (info.st_mode & S_IFMT) == S_IFREG
        )
        guard observed == identity else { return false }
        let flags = identity.isDirectory ? AT_REMOVEDIR : 0
        let removed = url.lastPathComponent.withCString {
            Darwin.unlinkat(descriptor, $0, flags)
        }
        guard removed == 0 else { throw Self.posixError() }
        guard Darwin.fsync(descriptor) == 0 else { throw Self.posixError() }
        return true
    }

    public func copy(_ source: URL, to destination: URL) throws {
        try copy(source, to: destination, exclusively: false)
    }

    public func copyExclusively(_ source: URL, to destination: URL) throws {
        if try Self.entryTypeNoFollow(destination, allowingMissing: true) != nil {
            throw Self.posixError(EEXIST)
        }
        try copy(source, to: destination, exclusively: true)
    }

    private func copy(_ source: URL, to destination: URL, exclusively: Bool) throws {
        let sourceHandle = try FileHandle(forReadingFrom: source)
        var sourceIsClosed = false
        defer {
            if !sourceIsClosed {
                try? sourceHandle.close()
            }
        }

        try installAtomically(to: destination, exclusively: exclusively) { destinationHandle in
            while let chunk = try sourceHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try destinationHandle.write(contentsOf: chunk)
            }
            try sourceHandle.close()
            sourceIsClosed = true
        }
    }

    public func replace(_ target: URL, with preparedFile: URL) throws {
        try validateRegularPreparedFile(preparedFile)
        try validateReplacementTarget(target)
        try synchronizeDirectories(for: target, and: preparedFile)
        try beforeAtomicReplacement(target, preparedFile)
        try Self.renameNoFollow(preparedFile, target, exclusively: false)

        // The rename is the commit point. Throwing after it would report failure
        // after the previous bytes have already ceased to be addressable. Directory
        // synchronization is therefore preflighted above; after commit it is retried
        // best-effort without violating the all-reported-errors-preserve-old-bytes
        // contract.
        try? Self.synchronizeDirectoryDescriptors(for: target, and: preparedFile)
    }

    public func exchange(_ target: URL, with preparedFile: URL) throws {
        try Self.renameItem(target, preparedFile, flags: UInt32(RENAME_SWAP))
        do {
            try synchronizeDirectories(for: target, and: preparedFile)
        } catch let synchronizationError {
            do {
                try Self.renameItem(target, preparedFile, flags: UInt32(RENAME_SWAP))
                try synchronizeDirectories(for: target, and: preparedFile)
            } catch {
                throw AtomicFileStoreError.exchangeRecoveryFailed(target)
            }
            throw synchronizationError
        }
    }

    public func installExclusively(_ target: URL, from preparedFile: URL) throws {
        try validateRegularPreparedFile(preparedFile)
        try synchronizeDirectories(for: target, and: preparedFile)
        try Self.renameNoFollow(preparedFile, target, exclusively: true)
        try? Self.synchronizeDirectoryDescriptors(for: target, and: preparedFile)
    }

    public func remove(_ url: URL) throws {
        if exists(url) {
            try manager.removeItem(at: url)
            try synchronizeDirectory(url.deletingLastPathComponent())
        }
    }

    private func validateRegularPreparedFile(_ url: URL) throws {
        guard try Self.entryTypeNoFollow(url) == S_IFREG else {
            throw AtomicFileStoreError.unsafeReplacementTarget(url)
        }
    }

    private func validateReplacementTarget(_ url: URL) throws {
        guard let type = try Self.entryTypeNoFollow(url, allowingMissing: true) else { return }
        guard type == S_IFREG else {
            throw AtomicFileStoreError.unsafeReplacementTarget(url)
        }
    }

    public func writeAtomically(_ data: Data, to target: URL) throws {
        try installAtomically(to: target, exclusively: false) { handle in
            try handle.write(contentsOf: data)
        }
    }

    public func writeExclusively(_ data: Data, to target: URL) throws {
        if try Self.entryTypeNoFollow(target, allowingMissing: true) != nil {
            throw Self.posixError(EEXIST)
        }
        try installAtomically(to: target, exclusively: true) { handle in
            try handle.write(contentsOf: data)
        }
    }

    private func installAtomically(
        to target: URL,
        exclusively: Bool,
        writing contents: (FileHandle) throws -> Void
    ) throws {
        try createDirectory(target.deletingLastPathComponent())
        let (temporary, handle) = try makeTemporaryFile(nextTo: target)
        var handleIsClosed = false
        defer {
            if !handleIsClosed {
                try? handle.close()
            }
        }

        try contents(handle)
        try handle.synchronize()
        try handle.close()
        handleIsClosed = true
        if exclusively {
            try installExclusively(target, from: temporary)
        } else {
            try replace(target, with: temporary)
        }
    }

    private func makeTemporaryFile(nextTo target: URL) throws -> (URL, FileHandle) {
        let directory = target.deletingLastPathComponent()
        guard let parent = try Self.openDirectoryNoFollow(directory) else {
            throw Self.posixError(ELOOP)
        }
        defer { _ = Darwin.close(parent) }

        for _ in 0..<100 {
            let name = ".\(target.lastPathComponent).wallume.tmp.\(UUID().uuidString)"
            let descriptor = name.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
            }
            if descriptor >= 0 {
                return (
                    directory.appending(path: name),
                    FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                )
            }
            if errno != EEXIST { throw Self.posixError() }
        }
        throw Self.posixError(EEXIST)
    }

    private static func renameItem(_ source: URL, _ destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw posixError()
        }
    }

    private static func renameNoFollow(
        _ source: URL,
        _ destination: URL,
        exclusively: Bool
    ) throws {
        guard let sourceDirectory = try openDirectoryNoFollow(source.deletingLastPathComponent()),
              let destinationDirectory = try openDirectoryNoFollow(destination.deletingLastPathComponent()) else {
            throw posixError(ELOOP)
        }
        defer {
            _ = Darwin.close(sourceDirectory)
            _ = Darwin.close(destinationDirectory)
        }
        let result = source.lastPathComponent.withCString { sourceName in
            destination.lastPathComponent.withCString { destinationName in
                if exclusively {
                    return Darwin.renameatx_np(
                        sourceDirectory,
                        sourceName,
                        destinationDirectory,
                        destinationName,
                        UInt32(RENAME_EXCL)
                    )
                }
                return Darwin.renameat(
                    sourceDirectory,
                    sourceName,
                    destinationDirectory,
                    destinationName
                )
            }
        }
        guard result == 0 else { throw posixError() }
    }

    private static func renameItem(_ source: URL, _ destination: URL, flags: UInt32) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    flags
                )
            }
        }
        guard result == 0 else { throw posixError() }
    }

    private func synchronizeDirectories(for first: URL, and second: URL) throws {
        let firstDirectory = first.deletingLastPathComponent()
        let secondDirectory = second.deletingLastPathComponent()
        try synchronizeDirectory(firstDirectory)
        if secondDirectory != firstDirectory {
            try synchronizeDirectory(secondDirectory)
        }
    }

    private static func synchronizeDirectoryEntry(_ directory: URL) throws {
        guard let descriptor = try openDirectoryNoFollow(directory) else { throw posixError(ELOOP) }

        if Darwin.fsync(descriptor) != 0 {
            let error = posixError()
            _ = Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            throw posixError()
        }
    }

    private static func synchronizeDirectoryDescriptors(
        for first: URL,
        and second: URL
    ) throws {
        let firstDirectory = first.deletingLastPathComponent()
        let secondDirectory = second.deletingLastPathComponent()
        guard let firstDescriptor = try openDirectoryNoFollow(firstDirectory) else {
            throw posixError(ELOOP)
        }
        defer { _ = Darwin.close(firstDescriptor) }
        guard Darwin.fsync(firstDescriptor) == 0 else { throw posixError() }
        if secondDirectory != firstDirectory {
            guard let secondDescriptor = try openDirectoryNoFollow(secondDirectory) else {
                throw posixError(ELOOP)
            }
            defer { _ = Darwin.close(secondDescriptor) }
            guard Darwin.fsync(secondDescriptor) == 0 else { throw posixError() }
        }
    }

    private static func entryTypeNoFollow(
        _ url: URL,
        allowingMissing: Bool = false
    ) throws -> mode_t? {
        guard let descriptor = try openDirectoryNoFollow(url.deletingLastPathComponent()) else {
            throw posixError(ELOOP)
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        let status = url.lastPathComponent.withCString {
            Darwin.fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0, allowingMissing, errno == ENOENT { return nil }
        guard status == 0 else { throw posixError() }
        return info.st_mode & S_IFMT
    }

    private static func openDirectoryNoFollow(_ directory: URL) throws -> Int32? {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        // Foundation exposes the system temporary directory through `/var`, whose
        // root entry is the platform-owned `/private/var` compatibility symlink.
        // Canonicalize that one OS alias before enforcing no-follow traversal on
        // every application-controlled component below it.
        let path = directory.path == "/var" || directory.path.hasPrefix("/var/")
            ? "/private" + directory.path
            : directory.path
        for component in path.split(separator: "/").map(String.init) {
            var info = stat()
            let status = component.withCString {
                Darwin.fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                let error = posixError()
                _ = Darwin.close(descriptor)
                throw error
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                _ = Darwin.close(descriptor)
                return nil
            }
            let next = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                let code = errno
                _ = Darwin.close(descriptor)
                if code == ELOOP { return nil }
                throw posixError(code)
            }
            _ = Darwin.close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
