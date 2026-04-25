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

    func normalizeOpenRouterProviders(
        _ request: PortableCoreOpenRouterNormalizationRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreOpenRouterNormalizationResult {
        try self.call(operation: .normalizeOpenRouterProviders, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func makeOpenRouterCompatPersistence(
        _ request: PortableCoreOpenRouterCompatPersistenceRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreOpenRouterCompatPersistenceResult {
        try self.call(operation: .makeOpenRouterCompatPersistence, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func reconcileOAuthAuthSnapshot(
        _ request: PortableCoreOAuthAuthReconciliationRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreOAuthAuthReconciliationResult {
        try self.call(operation: .reconcileOAuthAuthSnapshot, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func normalizeSharedTeamOrganizationNames(
        _ request: PortableCoreSharedTeamOrganizationNormalizationRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreSharedTeamOrganizationNormalizationResult {
        try self.call(operation: .normalizeSharedTeamOrganizationNames, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func normalizeReservedProviderIds(
        _ request: PortableCoreReservedProviderIdNormalizationRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreReservedProviderIdNormalizationResult {
        try self.call(operation: .normalizeReservedProviderIds, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func refreshOAuthAccountMetadata(
        _ request: PortableCoreOAuthMetadataRefreshRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreOAuthMetadataRefreshResult {
        try self.call(operation: .refreshOAuthAccountMetadata, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func parseLegacyCodexToml(
        _ request: PortableCoreLegacyCodexTomlParseRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreLegacyCodexTomlParseResult {
        try self.call(operation: .parseLegacyCodexToml, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func parseProviderSecretsEnv(
        _ request: PortableCoreProviderSecretsEnvParseRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreProviderSecretsEnvParseResult {
        try self.call(operation: .parseProviderSecretsEnv, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func resolveLegacyMigrationActiveSelection(
        _ request: PortableCoreLegacyMigrationActiveSelectionRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreLegacyMigrationActiveSelectionResult {
        try self.call(
            operation: .resolveLegacyMigrationActiveSelection,
            payload: request,
            buildIfNeeded: buildIfNeeded
        )
    }

    func planLegacyImportedProvider(
        _ request: PortableCoreLegacyImportedProviderPlanRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreLegacyImportedProviderPlanResult {
        try self.call(
            operation: .planLegacyImportedProvider,
            payload: request,
            buildIfNeeded: buildIfNeeded
        )
    }

    func normalizeOAuthAccountIdentities(
        _ request: PortableCoreOAuthIdentityNormalizationRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreOAuthIdentityNormalizationResult {
        try self.call(
            operation: .normalizeOAuthAccountIdentities,
            payload: request,
            buildIfNeeded: buildIfNeeded
        )
    }

    func parseAuthJsonSnapshot(
        _ request: PortableCoreAuthJSONSnapshotParseRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreAuthJSONSnapshotParseResult {
        try self.call(operation: .parseAuthJsonSnapshot, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func describeFullRustCutoverContract(
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreFullRustCutoverContract {
        try self.call(
            operation: .describeFullRustCutoverContract,
            payload: JSONValue.null,
            buildIfNeeded: buildIfNeeded
        )
    }

    func parseSessionTranscript(
        _ request: PortableCoreSessionTranscriptParseRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreSessionTranscriptParseResult {
        try self.call(operation: .parseSessionTranscript, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func resolveRecentOpenRouterModel(
        _ request: PortableCoreRecentOpenRouterModelRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreRecentOpenRouterModelResult {
        try self.call(operation: .resolveRecentOpenRouterModel, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func planStorePaths(
        _ request: PortableCoreStorePathPlanRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreStorePathPlan {
        try self.call(operation: .planStorePaths, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func planUsagePolling(
        _ request: PortableCoreUsagePollingPlanRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreUsagePollingPlanResult {
        try self.call(operation: .planUsagePolling, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func resolveUsageModeTransition(
        _ request: PortableCoreUsageModeTransitionRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreUsageModeTransitionResult {
        try self.call(operation: .resolveUsageModeTransition, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func resolveProviderRemovalTransition(
        _ request: PortableCoreProviderRemovalTransitionRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreProviderRemovalTransitionResult {
        try self.call(operation: .resolveProviderRemovalTransition, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func summarizeLocalCost(
        _ request: PortableCoreLocalCostSummaryRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreLocalCostSummarySnapshot {
        try self.call(operation: .summarizeLocalCost, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func attributeLiveSessions(
        _ request: PortableCoreLiveSessionAttributionRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreLiveSessionAttributionResult {
        try self.call(operation: .attributeLiveSessions, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func attributeRunningThreads(
        _ request: PortableCoreRunningThreadAttributionRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreRunningThreadAttributionResult {
        try self.call(operation: .attributeRunningThreads, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func projectSessionUsageLedger(
        _ request: PortableCoreSessionUsageLedgerProjectionRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreSessionUsageLedgerProjectionResult {
        try self.call(operation: .projectSessionUsageLedger, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func resolveGatewayTransportPolicy(
        _ request: PortableCoreGatewayTransportPolicyRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGatewayTransportPolicyResult {
        try self.call(operation: .resolveGatewayTransportPolicy, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func resolveGatewayStatusPolicy(
        _ request: PortableCoreGatewayStatusPolicyRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGatewayStatusPolicyResult {
        try self.call(operation: .resolveGatewayStatusPolicy, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func resolveGatewayStickyRecoveryPolicy(
        _ request: PortableCoreGatewayStickyRecoveryPolicyRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGatewayStickyRecoveryPolicyResult {
        try self.call(operation: .resolveGatewayStickyRecoveryPolicy, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func interpretGatewayProtocolSignal(
        _ request: PortableCoreGatewayProtocolSignalInterpretationRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGatewayProtocolSignalInterpretationResult {
        try self.call(operation: .interpretGatewayProtocolSignal, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func decideGatewayProtocolPreview(
        _ request: PortableCoreGatewayProtocolPreviewDecisionRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGatewayProtocolPreviewDecisionResult {
        try self.call(operation: .decideGatewayProtocolPreview, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func planGatewayCandidates(
        _ request: PortableCoreGatewayCandidatePlanRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGatewayCandidatePlanResult {
        try self.call(operation: .planGatewayCandidates, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func bindGatewayStickyState(
        _ request: PortableCoreGatewayStickyBindRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGatewayStickyBindResult {
        try self.call(operation: .bindGatewayStickyState, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func clearGatewayStickyState(
        _ request: PortableCoreGatewayStickyClearRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGatewayStickyClearResult {
        try self.call(operation: .clearGatewayStickyState, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func applyGatewayRuntimeBlock(
        _ request: PortableCoreGatewayRuntimeBlockApplyRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGatewayRuntimeBlockApplyResult {
        try self.call(operation: .applyGatewayRuntimeBlock, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func normalizeGatewayState(
        _ request: PortableCoreGatewayStateNormalizationRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGatewayStateNormalizationResult {
        try self.call(operation: .normalizeGatewayState, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func normalizeOpenAIResponsesRequest(
        _ request: PortableCoreOpenAIResponsesRequestNormalizationRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreOpenAIResponsesRequestNormalizationResult {
        try self.call(operation: .normalizeOpenAIResponsesRequest, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func normalizeOpenRouterRequest(
        _ request: PortableCoreOpenRouterRequestNormalizationRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreOpenRouterRequestNormalizationResult {
        try self.call(operation: .normalizeOpenRouterRequest, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func resolveOpenRouterGatewayAccountState(
        _ request: PortableCoreOpenRouterGatewayAccountStateRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreOpenRouterGatewayAccountStateResult {
        try self.call(operation: .resolveOpenRouterGatewayAccountState, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func planGatewayLifecycle(
        _ request: PortableCoreGatewayLifecyclePlanRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGatewayLifecyclePlanResult {
        try self.call(operation: .planGatewayLifecycle, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func planAggregateGatewayLeaseTransition(
        _ request: PortableCoreAggregateGatewayLeaseTransitionPlanRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreAggregateGatewayLeaseTransitionPlanResult {
        try self.call(
            operation: .planAggregateGatewayLeaseTransition,
            payload: request,
            buildIfNeeded: buildIfNeeded
        )
    }

    func planAggregateGatewayLeaseRefresh(
        _ request: PortableCoreAggregateGatewayLeaseRefreshPlanRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreAggregateGatewayLeaseRefreshPlanResult {
        try self.call(
            operation: .planAggregateGatewayLeaseRefresh,
            payload: request,
            buildIfNeeded: buildIfNeeded
        )
    }

    func decideGatewayPostCompletionBinding(
        _ request: PortableCoreGatewayPostCompletionBindingDecisionRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGatewayPostCompletionBindingDecisionResult {
        try self.call(
            operation: .decideGatewayPostCompletionBinding,
            payload: request,
            buildIfNeeded: buildIfNeeded
        )
    }

    func buildOAuthAuthorizationUrl(
        _ request: PortableCoreOAuthAuthorizationUrlRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreOAuthAuthorizationUrlResult {
        try self.call(operation: .buildOAuthAuthorizationUrl, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func interpretOAuthCallback(
        _ request: PortableCoreOAuthCallbackInterpretationRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreOAuthCallbackInterpretationResult {
        try self.call(operation: .interpretOAuthCallback, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func resolveUpdateAvailability(
        _ request: PortableCoreUpdateResolutionRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreUpdateAvailabilityResult {
        try self.call(operation: .resolveUpdateAvailability, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func selectInstallableGitHubReleaseFromJSON(
        _ request: PortableCoreGitHubInstallableReleaseSelectionFromJSONRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreGitHubInstallableReleaseSelectionResult {
        try self.call(operation: .selectInstallableGitHubReleaseFromJSON, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func selectUpdateArtifact(
        _ request: PortableCoreUpdateArtifactSelectionRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreUpdateArtifactSelectionResult {
        try self.call(operation: .selectUpdateArtifact, payload: request, buildIfNeeded: buildIfNeeded)
    }

    func evaluateUpdateBlockers(
        _ request: PortableCoreUpdateBlockerEvaluationRequest,
        buildIfNeeded: Bool = false
    ) throws -> PortableCoreUpdateBlockerEvaluationResult {
        try self.call(operation: .evaluateUpdateBlockers, payload: request, buildIfNeeded: buildIfNeeded)
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

    func forceRebuildForTesting() throws {
        try Self.buildBridgeLibrary(forceRebuild: true)
        self.resetForTesting()
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
        try Self.buildBridgeLibraryIfNeeded()
        if buildIfNeeded {
            try Self.buildBridgeLibrary(forceRebuild: false)
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
        try self.buildBridgeLibrary(forceRebuild: false)
    }

    private static func buildBridgeLibrary(forceRebuild: Bool) throws {
        let repoRoot = self.repoRoot()
        let buildDirectory = repoRoot.appendingPathComponent("rust-core")
        let dylibPath = buildDirectory.appendingPathComponent("target/debug/libcodexbar_portable_core.dylib")
        if forceRebuild == false && self.shouldRebuildBridgeLibrary(dylibPath: dylibPath, buildDirectory: buildDirectory) == false {
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

    private static func shouldRebuildBridgeLibrary(
        dylibPath: URL,
        buildDirectory: URL
    ) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dylibPath.path) else { return true }
        guard let dylibAttributes = try? fileManager.attributesOfItem(atPath: dylibPath.path),
              let dylibModifiedAt = dylibAttributes[.modificationDate] as? Date else {
            return true
        }

        let enumerator = fileManager.enumerator(
            at: buildDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "rs"
                || url.lastPathComponent == "Cargo.toml"
                || url.lastPathComponent == "Cargo.lock" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate else {
                continue
            }
            if modifiedAt > dylibModifiedAt {
                return true
            }
        }
        return false
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
