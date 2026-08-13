import Foundation

public struct QwenRuntimePaths: Equatable, Sendable {
    public let rootDirectory: URL
    public let virtualEnvironmentDirectory: URL
    public let pythonExecutable: URL
    public let modelCacheDirectory: URL
    public let uvCacheDirectory: URL
    public let logDirectory: URL

    public init(rootDirectory: URL) {
        let root = rootDirectory.standardizedFileURL
        self.rootDirectory = root
        virtualEnvironmentDirectory = root.appendingPathComponent(
            "venv",
            isDirectory: true
        )
        pythonExecutable = virtualEnvironmentDirectory.appendingPathComponent(
            "bin/python3",
            isDirectory: false
        )
        modelCacheDirectory = root.appendingPathComponent(
            "cache/huggingface",
            isDirectory: true
        )
        uvCacheDirectory = root.appendingPathComponent(
            "cache/uv",
            isDirectory: true
        )
        logDirectory = root.appendingPathComponent("logs", isDirectory: true)
    }

    public static func applicationSupport() throws -> QwenRuntimePaths {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw QwenRuntimeError.applicationSupportUnavailable
        }
        return QwenRuntimePaths(
            rootDirectory: applicationSupport
                .appendingPathComponent("Whisper", isDirectory: true)
                .appendingPathComponent("Qwen", isDirectory: true)
        )
    }
}

public enum QwenRuntimeError: LocalizedError, Equatable, Sendable {
    case unsupportedArchitecture
    case applicationSupportUnavailable
    case unsafeManagedPath(String)
    case cannotCreateRuntimeDirectory(String)
    case uvNotFound
    case bootstrapFailed(step: String, exitCode: Int32, details: String?)
    case invalidEnvironment
    case bundledWorkerMissing
    case workerAlreadyRunning
    case workerNotRunning
    case invalidRequest(String)
    case protocolViolation(String)
    case workerLaunchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            "Local Qwen speech requires an Apple silicon Mac."
        case .applicationSupportUnavailable:
            "The user Application Support directory is unavailable."
        case let .unsafeManagedPath(path):
            "The Qwen runtime path is not a safe managed directory: \(path)"
        case let .cannotCreateRuntimeDirectory(path):
            "Whisper could not create its Qwen runtime directory: \(path)"
        case .uvNotFound:
            "The uv runtime manager is required to install local Qwen speech."
        case let .bootstrapFailed(step, exitCode, details):
            if let details, !details.isEmpty {
                "Qwen setup failed during \(step) (exit \(exitCode)): \(details)"
            } else {
                "Qwen setup failed during \(step) (exit \(exitCode))."
            }
        case .invalidEnvironment:
            "The managed Qwen Python 3.12 environment is incomplete or incompatible."
        case .bundledWorkerMissing:
            "The bundled Qwen speech worker is missing."
        case .workerAlreadyRunning:
            "The Qwen speech worker is already running."
        case .workerNotRunning:
            "The Qwen speech worker is not running."
        case let .invalidRequest(message):
            "Invalid Qwen speech request: \(message)"
        case let .protocolViolation(message):
            "The Qwen speech worker returned invalid data: \(message)"
        case let .workerLaunchFailed(message):
            "The Qwen speech worker could not start: \(message)"
        }
    }
}

public final class QwenRuntimeBootstrapper: @unchecked Sendable {
    private static let dependency = "mlx-audio==\(QwenTTSCatalog.mlxAudioVersion)"
    private let paths: QwenRuntimePaths
    private let explicitUVExecutable: URL?
    private let fileManager: FileManager
    private let workQueue = DispatchQueue(
        label: "com.whisper.qwen-runtime-bootstrap",
        qos: .userInitiated
    )

    public init(
        paths: QwenRuntimePaths? = nil,
        uvExecutable: URL? = nil
    ) throws {
        self.paths = try paths ?? QwenRuntimePaths.applicationSupport()
        explicitUVExecutable = uvExecutable?.standardizedFileURL
        fileManager = .default
    }

    public func prepare(
        status: @escaping QwenRuntimeStatusHandler = { _ in }
    ) async throws -> QwenRuntimePaths {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async { [self] in
                do {
                    let prepared = try prepareSynchronously(status: status)
                    continuation.resume(returning: prepared)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func prepareSynchronously(
        status: QwenRuntimeStatusHandler
    ) throws -> QwenRuntimePaths {
#if !arch(arm64)
        throw QwenRuntimeError.unsupportedArchitecture
#endif
        status(.checkingRuntime)
        try createManagedDirectories()

        if runtimeIsValid() {
            status(.runtimeAvailable)
            return paths
        }

        status(.locatingUV)
        guard let uvExecutable = locateUVExecutable() else {
            throw QwenRuntimeError.uvNotFound
        }

        status(.creatingEnvironment)
        try runBootstrapStep(
            executable: uvExecutable,
            arguments: [
                "venv",
                "--python", "3.12",
                "--allow-existing",
                "--no-project",
                "--no-progress",
                "--cache-dir", paths.uvCacheDirectory.path,
                paths.virtualEnvironmentDirectory.path,
            ],
            step: "creating the Python 3.12 environment"
        )

        status(.installingDependencies)
        try runBootstrapStep(
            executable: uvExecutable,
            arguments: [
                "pip", "install",
                "--python", paths.pythonExecutable.path,
                "--no-progress",
                "--cache-dir", paths.uvCacheDirectory.path,
                Self.dependency,
            ],
            step: "installing \(Self.dependency)"
        )

        guard runtimeIsValid() else {
            throw QwenRuntimeError.invalidEnvironment
        }
        status(.runtimeAvailable)
        return paths
    }

    private func createManagedDirectories() throws {
        let directories = [
            paths.rootDirectory,
            paths.modelCacheDirectory,
            paths.uvCacheDirectory,
            paths.logDirectory,
        ]
        for directory in directories {
            try rejectSymbolicLink(at: directory)
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            } catch let error as QwenRuntimeError {
                throw error
            } catch {
                throw QwenRuntimeError.cannotCreateRuntimeDirectory(directory.path)
            }
        }
        try rejectSymbolicLink(at: paths.virtualEnvironmentDirectory)
    }

    private func rejectSymbolicLink(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
        )
        guard values?.isSymbolicLink != true,
              values?.isDirectory == true else {
            throw QwenRuntimeError.unsafeManagedPath(url.path)
        }
    }

    private func runtimeIsValid() -> Bool {
        guard fileManager.isExecutableFile(atPath: paths.pythonExecutable.path) else {
            return false
        }

        let process = Process()
        process.executableURL = paths.pythonExecutable
        process.arguments = [
            "-I",
            "-c",
            """
            import importlib.metadata as m, sys
            ok = sys.version_info[:2] == (3, 12) and m.version("mlx-audio") == "\(QwenTTSCatalog.mlxAudioVersion)"
            raise SystemExit(0 if ok else 1)
            """,
        ]
        process.environment = sanitizedEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func locateUVExecutable() -> URL? {
        var candidates: [URL] = []
        if let explicitUVExecutable {
            candidates.append(explicitUVExecutable)
        }

        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["WHISPER_UV_EXECUTABLE"],
           configured.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":").map(String.init)
            where directory.hasPrefix("/") {
                candidates.append(
                    URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent("uv", isDirectory: false)
                )
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        candidates.append(
            home.appendingPathComponent(".local/bin/uv", isDirectory: false)
        )
        candidates.append(
            home.appendingPathComponent(".cargo/bin/uv", isDirectory: false)
        )
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/uv"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/uv"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/uv"))

        var inspected = Set<String>()
        for candidate in candidates {
            let normalized = candidate.standardizedFileURL
            let resourceValues = try? normalized.resourceValues(
                forKeys: [.isRegularFileKey]
            )
            guard inspected.insert(normalized.path).inserted,
                  fileManager.isExecutableFile(atPath: normalized.path),
                  resourceValues?.isRegularFile == true else {
                continue
            }
            return normalized
        }
        return nil
    }

    private func runBootstrapStep(
        executable: URL,
        arguments: [String],
        step: String
    ) throws {
        let logURL = paths.logDirectory.appendingPathComponent(
            "bootstrap-\(UUID().uuidString).log",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: logURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw QwenRuntimeError.cannotCreateRuntimeDirectory(
                paths.logDirectory.path
            )
        }

        let logHandle: FileHandle
        do {
            logHandle = try FileHandle(forWritingTo: logURL)
        } catch {
            throw QwenRuntimeError.cannotCreateRuntimeDirectory(
                paths.logDirectory.path
            )
        }
        defer {
            try? logHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = sanitizedEnvironment()
        process.currentDirectoryURL = paths.rootDirectory
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw QwenRuntimeError.bootstrapFailed(
                step: step,
                exitCode: -1,
                details: safeDescription(error)
            )
        }

        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw QwenRuntimeError.bootstrapFailed(
                step: step,
                exitCode: process.terminationStatus,
                details: readLogTail(at: logURL)
            )
        }
    }

    private func sanitizedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let unsafeKeys = [
            "DYLD_FRAMEWORK_PATH",
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
            "PYTHONHOME",
            "PYTHONPATH",
            "VIRTUAL_ENV",
        ]
        for key in unsafeKeys {
            environment.removeValue(forKey: key)
        }
        environment["PYTHONNOUSERSITE"] = "1"
        environment["UV_CACHE_DIR"] = paths.uvCacheDirectory.path
        environment["UV_NO_PROGRESS"] = "1"
        environment["UV_NO_CONFIG"] = "1"
        return environment
    }

    private func readLogTail(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer {
            try? handle.close()
        }
        do {
            let length = try handle.seekToEnd()
            let maximumBytes: UInt64 = 16_384
            if length > maximumBytes {
                try handle.seek(toOffset: length - maximumBytes)
            } else {
                try handle.seek(toOffset: 0)
            }
            guard let data = try handle.readToEnd(),
                  !data.isEmpty else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{001B}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .suffix(8_000)
                .description
        } catch {
            return nil
        }
    }

    private func safeDescription(_ error: Error) -> String {
        if let cocoaError = error as? CocoaError {
            return cocoaError.localizedDescription
        }
        return "The process could not be launched."
    }
}
