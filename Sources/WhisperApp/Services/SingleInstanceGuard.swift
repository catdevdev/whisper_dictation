import Darwin
import Foundation

enum SingleInstanceGuardError: LocalizedError {
    case cachesDirectoryUnavailable
    case unsafeLockDirectory
    case unableToOpenLockDirectory(Int32)
    case unableToOpenLockFile(Int32)
    case unsafeLockFile
    case unableToLock(Int32)

    var errorDescription: String? {
        switch self {
        case .cachesDirectoryUnavailable:
            "The per-user caches directory is unavailable."
        case .unsafeLockDirectory:
            "The instance lock directory is not a private directory owned by this user."
        case let .unableToOpenLockDirectory(code):
            "The instance lock directory could not be opened (errno \(code))."
        case let .unableToOpenLockFile(code):
            "The instance lock file could not be opened (errno \(code))."
        case .unsafeLockFile:
            "The instance lock file is not a regular file owned by this user."
        case let .unableToLock(code):
            "The instance lock could not be acquired (errno \(code))."
        }
    }
}

/// Holds a nonblocking per-user process lock for the complete application lifetime.
final class SingleInstanceGuard {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    /// Returns `nil` when another Whisper process already owns the lock.
    static func acquire(
        fileManager: FileManager = .default
    ) throws -> SingleInstanceGuard? {
        guard let cachesDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw SingleInstanceGuardError.cachesDirectoryUnavailable
        }

        let lockDirectory = cachesDirectory
            .appendingPathComponent("com.nekoneki.whisper-dictation", isDirectory: true)
        try fileManager.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )

        let directoryDescriptor = open(
            lockDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw SingleInstanceGuardError.unableToOpenLockDirectory(errno)
        }

        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & S_IFMT == S_IFDIR else {
            _ = close(directoryDescriptor)
            throw SingleInstanceGuardError.unsafeLockDirectory
        }
        _ = fchmod(directoryDescriptor, mode_t(S_IRWXU))

        let descriptor = openat(
            directoryDescriptor,
            "instance.lock",
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        let openError = errno
        _ = close(directoryDescriptor)
        guard descriptor >= 0 else {
            throw SingleInstanceGuardError.unableToOpenLockFile(openError)
        }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_uid == geteuid(),
              fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_nlink == 1 else {
            _ = close(descriptor)
            throw SingleInstanceGuardError.unsafeLockFile
        }
        _ = fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR))

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return nil
            }
            throw SingleInstanceGuardError.unableToLock(lockError)
        }

        return SingleInstanceGuard(descriptor: descriptor)
    }
}
