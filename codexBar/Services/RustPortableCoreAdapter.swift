import Darwin
import Foundation

enum RustPortableCoreRuntimeMode: String {
    case legacy
    case shadow
    case primary
}

final class PortableCoreRollbackController {
    static let shared = PortableCoreRollbackController()

    private let queue = DispatchQueue(label: "lzl.codexbar.portable-core.rollback")
    private var disabledReason: String?

    private init() {}

    var isEnabled: Bool {
        self.queue.sync { self.disabledReason == nil }
    }

    var currentDisabledReason: String? {
        self.queue.sync { self.disabledReason }
    }

    func disable(reason: String) {
        self.queue.sync {
            self.disabledReason = reason
        }
    }

    func reset() {
        self.queue.sync {
            self.disabledReason = nil
        }
    }
}

enum RustPortableCoreAdapterError: Error, LocalizedError {
    case dylibNotFound([String])
    case dylibLoadFailed(String)
    case symbolMissing(String)
    case bridgeReturnedInvalidUTF8
    case bridgeError(PortableCoreFFIError)
    case buildFailed(String)

    var errorDescription: String? {
        switch self {
        case .dylibNotFound(let candidates):
            return "未找到 Rust portable core dylib: \(candidates.joined(separator: ", "))"
        case .dylibLoadFailed(let message):
            return "加载 Rust portable core 失败: \(message)"
        case .symbolMissing(let symbol):
            return "Rust portable core 缺少符号: \(symbol)"
        case .bridgeReturnedInvalidUTF8:
            return "Rust portable core 返回了无效 UTF-8"
        case .bridgeError(let error):
            return "\(error.code): \(error.message)"
        case .buildFailed(let message):
            return "构建 Rust portable core 失败: \(message)"
        }
    }
}

final class RustPortableCoreAdapter {
    static let shared = RustPortableCoreAdapter()

    typealias ExecuteFunction = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    typealias FreeStringFunction = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private let stateQueue = DispatchQueue(label: "lzl.codexbar.portable-core.adapter")
    private var handle: UnsafeMutableRawPointer?
    private var executeFunction: ExecuteFunction?
    private var freeStringFunction: FreeStringFunction?
    private var loadedPath: String?

    private init() {}

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    func runtimeMode() -> RustPortableCoreRuntimeMode {
        if let raw = ProcessInfo.processInfo.environment["CODEXBAR_RUST_PORTABLE_CORE_MODE"],
           let mode = RustPortableCoreRuntimeMode(rawValue: raw) {
            return mode
        }
        return .legacy
    }

    func warmup(buildIfNeeded: Bool = false) throws {
        _ = try self.ensureLoaded(buildIfNeeded: buildIfNeeded)
    }

    func canonicalizeConfigAndAccounts(
        _ input: PortableCoreRawConfigInput,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreCanonicalizationResult {
        try self.call(
            operation: .canonicalizeConfigAndAccounts,
            payload: input,
            buildIfNeeded: buildIfNeeded
        )
    }

    func computeRouteRuntimeSnapshot(
        _ input: PortableCoreRouteRuntimeInput,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreRouteRuntimeSnapshotDTO {
        try self.call(
            operation: .computeRouteRuntimeSnapshot,
            payload: input,
            buildIfNeeded: buildIfNeeded
        )
    }

    func renderCodecBundle(
        _ request: PortableCoreRenderCodecRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreRenderCodecOutput {
        try self.call(operation: .renderCodecBundle, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func planRefresh(
        _ request: PortableCoreRefreshPlanRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreRefreshPlanResult {
        try self.call(operation: .planRefresh, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func applyRefreshOutcome(
        _ request: PortableCoreRefreshOutcomeRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreRefreshOutcomeResult {
        try self.call(operation: .applyRefreshOutcome, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func mergeUsageSuccess(
        _ request: PortableCoreUsageMergeSuccessRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreUsageMergeResult {
        try self.call(operation: .mergeUsageSuccess, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func markUsageForbidden(
        account: PortableCoreCanonicalAccountSnapshot,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreUsageMergeResult {
        try self.call(operation: .markUsageForbidden, payload: account, buildIfNeeded: buildIfNeeded)
    }

    func markUsageTokenExpired(
        account: PortableCoreCanonicalAccountSnapshot,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreUsageMergeResult {
        try self.call(operation: .markUsageTokenExpired, payload: account, buildIfNeeded: buildIfNeeded)
    }

    func loadedLibraryPath() -> String? {
        self.stateQueue.sync { self.loadedPath }
    }

    func resetForTesting() {
        self.stateQueue.sync {
            if let handle = self.handle {
                dlclose(handle)
            }
            self.handle = nil
            self.executeFunction = nil
            self.freeStringFunction = nil
            self.loadedPath = nil
        }
    }

    private func call<Result: Decodable, Payload: Encodable>(
        operation: PortableCoreOperation,
        payload: Payload,
        buildIfNeeded: Bool
    ) throws -> Result {
        let execute = try self.ensureLoaded(buildIfNeeded: buildIfNeeded)
        let request = try PortableCoreFFIRequest(operation: operation, payload: payload).encodedJSONString()
        guard let requestCString = request.cString(using: .utf8) else {
            throw RustPortableCoreAdapterError.bridgeReturnedInvalidUTF8
        }
        let responsePointer = requestCString.withUnsafeBufferPointer { buffer -> UnsafeMutablePointer<CChar>? in
            execute(buffer.baseAddress)
        }
        guard let responsePointer else {
            throw RustPortableCoreAdapterError.bridgeReturnedInvalidUTF8
        }
        let freeString = try self.freeString()
        defer { freeString(responsePointer) }
        guard let responseJSONString = String(validatingUTF8: responsePointer) else {
            throw RustPortableCoreAdapterError.bridgeReturnedInvalidUTF8
        }
        let responseData = Data(responseJSONString.utf8)
        let response = try JSONDecoder.portableCore.decode(
            PortableCoreFFIResponse<Result>.self,
            from: responseData
        )
        if let error = response.error {
            throw RustPortableCoreAdapterError.bridgeError(error)
        }
        guard let result = response.result else {
            throw RustPortableCoreAdapterError.bridgeError(
                PortableCoreFFIError(code: "missingResult", message: "Rust portable core 未返回 result")
            )
        }
        return result
    }

    private func ensureLoaded(buildIfNeeded: Bool) throws -> ExecuteFunction {
        if let execute = self.stateQueue.sync(execute: { self.executeFunction }) {
            return execute
        }
        if buildIfNeeded {
            try Self.buildBridgeLibraryIfNeeded()
        }
        let candidates = Self.defaultDylibCandidates()
        let selectedPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
        guard let selectedPath else {
            throw RustPortableCoreAdapterError.dylibNotFound(candidates)
        }
        guard let handle = dlopen(selectedPath, RTLD_NOW | RTLD_LOCAL) else {
            throw RustPortableCoreAdapterError.dylibLoadFailed(String(cString: dlerror()))
        }
        guard let executeSymbol = dlsym(handle, "codexbar_portable_core_execute") else {
            dlclose(handle)
            throw RustPortableCoreAdapterError.symbolMissing("codexbar_portable_core_execute")
        }
        guard let freeSymbol = dlsym(handle, "codexbar_portable_core_free_string") else {
            dlclose(handle)
            throw RustPortableCoreAdapterError.symbolMissing("codexbar_portable_core_free_string")
        }

        let execute = unsafeBitCast(executeSymbol, to: ExecuteFunction.self)
        let freeString = unsafeBitCast(freeSymbol, to: FreeStringFunction.self)
        self.stateQueue.sync {
            self.handle = handle
            self.executeFunction = execute
            self.freeStringFunction = freeString
            self.loadedPath = selectedPath
        }
        return execute
    }

    private func freeString() throws -> FreeStringFunction {
        if let freeString = self.stateQueue.sync(execute: { self.freeStringFunction }) {
            return freeString
        }
        _ = try self.ensureLoaded(buildIfNeeded: false)
        guard let freeString = self.stateQueue.sync(execute: { self.freeStringFunction }) else {
            throw RustPortableCoreAdapterError.symbolMissing("codexbar_portable_core_free_string")
        }
        return freeString
    }

    private static func buildBridgeLibraryIfNeeded() throws {
        let repoRoot = self.repoRoot()
        let buildDirectory = repoRoot.appendingPathComponent("rust-core")
        let dylibPath = buildDirectory.appendingPathComponent("target/debug/libcodexbar_portable_core.dylib")
        if FileManager.default.fileExists(atPath: dylibPath.path) {
            return
        }

        let process = Process()
        process.currentDirectoryURL = buildDirectory
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["cargo", "build", "-p", "bridge_ffi"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw RustPortableCoreAdapterError.buildFailed(output)
        }
    }

    private static func defaultDylibCandidates() -> [String] {
        let env = ProcessInfo.processInfo.environment["CODEXBAR_RUST_PORTABLE_CORE_DYLIB"]
        let repoRoot = self.repoRoot()
        return [
            env,
            repoRoot.appendingPathComponent("rust-core/target/debug/libcodexbar_portable_core.dylib").path,
            repoRoot.appendingPathComponent("rust-core/target/release/libcodexbar_portable_core.dylib").path,
        ].compactMap { $0 }
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
