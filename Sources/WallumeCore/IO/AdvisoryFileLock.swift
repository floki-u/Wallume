import Darwin
import Foundation

@_silgen_name("flock")
private func wallumeFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public protocol AdvisoryLockToken: AnyObject, Sendable {}

public protocol AdvisoryLocking: Sendable {
    func acquire() throws -> any AdvisoryLockToken
}

public final class FileAdvisoryLockToken: AdvisoryLockToken, @unchecked Sendable {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

    deinit {
        _ = wallumeFlock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

public struct FileAdvisoryLock: AdvisoryLocking {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func acquire() throws -> any AdvisoryLockToken {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        guard wallumeFlock(descriptor, LOCK_EX) == 0 else {
            let error = posixError()
            _ = Darwin.close(descriptor)
            throw error
        }
        return FileAdvisoryLockToken(descriptor: descriptor)
    }

    private func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
