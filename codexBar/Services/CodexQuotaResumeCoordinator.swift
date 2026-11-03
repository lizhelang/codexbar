import AppKit
import Combine
import Darwin
import Foundation

/// 只在额度失败仍是最新轮次时发送一次。dispatching 必须先落盘；未知回执不自动重发。
@MainActor
final class CodexQuotaResumeCoordinator: ObservableObject, LifecycleControlling {
    typealias Observation = CodexQuotaResumeObservationStore.Observation

    enum Status: String, Codable {
        case waiting, needsAttention, dispatching, queued, uncertain, resumed, cancelled

        var canCancel: Bool { self == .waiting || self == .needsAttention }
        var wasDispatched: Bool { [.dispatching, .queued, .uncertain].contains(self) }
    }

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let threadID: String
        let failedTurnID: String
        let accountID: String
        let title: String
        let failureAt: Date
        let revision: String
        var status: Status = .waiting
        var nextCheckAt: Date
        var detail: String = "等待检查额度"
        var receipt: CodexThreadContinuationBridge.Receipt?
        var dispatchedAt: Date?
        var requiresObservedBlock = false
    }

    struct State: Codable, Equatable {
        var version = 1
        var enabled = false
        var enabledAt: Date?
        /// 由用户明确选定的监测账户；不根据创建账户或当前激活账户自动猜测。
        var accountID: String?
        var watchedThreads: [String: String] = [:]
        var entries: [Entry] = []
    }

    static let shared = makeLive()
    @Published private(set) var state: State
    @Published private(set) var isChecking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var capabilityMessage: String?
    @Published private(set) var recentThreads: [Observation] = []

    private let storageURL: URL
    private let list: (Date, Set<String>) async throws -> [Observation]
    private let read: (String) async throws -> Observation?
    private let quota: (String, String?) async throws -> CodexQuotaResumeQuota.Decision
    private let identityIsValid: (String) -> Bool
    private let resolveDesktopAccount: () -> CodexQuotaResumeAccountResolution
    private let bridge: any CodexThreadContinuing
    private let now: () -> Date
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var generation = 0
    private var storageFailed = false
    private var lockDescriptor: Int32 = -1

    init(
        storageURL: URL,
        list: @escaping (Date, Set<String>) async throws -> [Observation],
        read: @escaping (String) async throws -> Observation?,
        quota: @escaping (String, String?) async throws -> CodexQuotaResumeQuota.Decision,
        identityIsValid: @escaping (String) -> Bool,
        bridge: any CodexThreadContinuing,
        resolveDesktopAccount: @escaping () -> CodexQuotaResumeAccountResolution = {
            .unavailable(reason: "尚未识别到桌面端当前账号，请检查登录状态。")
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.storageURL = storageURL
        self.list = list
        self.read = read
        self.quota = quota
        self.identityIsValid = identityIsValid
        self.resolveDesktopAccount = resolveDesktopAccount
        self.bridge = bridge
        self.now = now
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) {
                self.state = try JSONDecoder().decode(State.self, from: Data(contentsOf: storageURL))
                if self.state.version != 1 { throw CocoaError(.fileReadCorruptFile) }
            } else {
                self.state = State()
            }
        } catch {
            self.state = State()
            self.storageFailed = true
            self.errorMessage = "守候记录无法读取，自动续跑已停止。原文件已保留。"
        }
    }

    private static func makeLive() -> CodexQuotaResumeCoordinator {
        let observer = CodexQuotaResumeObservationStore(codexRootURL: CodexPaths.codexRoot)
        let tokens = TokenStore.shared
        let resolveAccount: () -> CodexQuotaResumeAccountResolution = {
            // 仅读取身份，不修改登录文件、不把凭据存入守候记录。
            let data = try? Data(contentsOf: CodexPaths.authURL)
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let auth = json?["tokens"] as? [String: Any]
            return CodexQuotaResumeAccountResolution.resolve(
                mode: tokens.config.openAI.accountUsageMode,
                isOpenAIProvider: tokens.activeProvider?.kind == .openAIOAuth,
                activeAccount: tokens.activeAccount(),
                authRemoteAccountID: auth?["account_id"] as? String,
                authAccessToken: auth?["access_token"] as? String
            )
        }
        return CodexQuotaResumeCoordinator(
            storageURL: CodexPaths.codexBarRoot.appendingPathComponent("quota-resume.json"),
            list: { since, ids in
                try await Task.detached(priority: .utility) { try observer.load(since: since, includingThreadIDs: ids) }.value
            },
            read: { id in
                try await Task.detached(priority: .utility) { try observer.observation(threadID: id) }.value
            },
            quota: { accountID, model in
                guard let account = tokens.accounts.first(where: { $0.id == accountID }),
                      !account.isSuspended, !account.tokenExpired else {
                    return .unavailable(reason: "监测账号不可用，请检查登录")
                }
                let snapshot = try await WhamService.shared.fetchResumeQuota(account: account)
                return snapshot.decision(expectedAccountID: account.remoteAccountId, model: model)
            },
            identityIsValid: { resolveAccount().accountID == $0 },
            bridge: CodexThreadContinuationBridge(configuredAppURL: {
                tokens.config.desktop.preferredCodexAppPath.map { URL(fileURLWithPath: $0) }
            }),
            resolveDesktopAccount: resolveAccount
        )
    }

    /// 开启即授权：此后本机桌面主线程的明确额度失败，可按所选账号额度恢复。
    /// 切换账号时取消旧守候；不会恢复开启前已经停止的历史任务。
    func configure(enabled: Bool, accountID: String?) {
        guard !self.storageFailed, self.acquireLease() else { return }
        let resolution = self.resolveDesktopAccount()
        // nil 是真正的“桌面端当前账号”选项，开启时解析并固定身份；后续换号仍停止守候。
        let accountID = accountID ?? (enabled ? resolution.accountID : self.state.accountID)
        if enabled {
            guard let accountID, self.identityIsValid(accountID) else {
                self.errorMessage = resolution.failureReason
                    ?? "所选账号与桌面端当前账号不一致，请选择“桌面端当前账号”或对应账号。"
                return
            }
        }
        self.generation += 1
        var next = self.state
        let scopeChanged = next.accountID != accountID
        if !enabled || scopeChanged {
            for i in next.entries.indices where next.entries[i].status.canCancel {
                next.entries[i].status = .cancelled
                next.entries[i].detail = "已取消守候"
            }
            next.watchedThreads = [:]
        }
        if enabled && (!next.enabled || scopeChanged) { next.enabledAt = self.now() }
        next.enabled = enabled
        next.accountID = accountID
        _ = self.commit(next)
    }

    var desktopAccountID: String? { self.resolveDesktopAccount().accountID }

    func accountSelectionDidChange() {
        // 只清除上次开启失败的文案；文件损坏等持久化错误不能被选择操作隐藏。
        if !self.storageFailed { self.errorMessage = nil }
    }

    func cancel(_ id: UUID) {
        guard self.acquireLease(), let index = self.state.entries.firstIndex(where: { $0.id == id }),
              self.state.entries[index].status.canCancel else { return }
        var next = self.state
        next.entries[index].status = .cancelled
        next.entries[index].detail = "已取消守候"
        _ = self.commit(next)
    }

    /// 用户明确确认此线程使用所选账号。创建身份不是执行身份，不能代替此绑定。
    func watch(threadID: String) {
        guard self.acquireLease(), self.state.enabled, let accountID = self.state.accountID,
              self.identityIsValid(accountID),
              let observed = self.recentThreads.first(where: { $0.threadID == threadID && Self.supports($0) }) else { return }
        var next = self.state
        next.watchedThreads[threadID] = accountID
        for i in next.entries.indices where next.entries[i].threadID == threadID && next.entries[i].status == .needsAttention {
            next.entries[i].status = .waiting
            next.entries[i].nextCheckAt = self.now()
        }
        // 显式重新选择可撤销未发送的取消；已提交/未知的请求仍不得重新发送。
        for i in next.entries.indices where next.entries[i].threadID == threadID
            && next.entries[i].status == .cancelled && next.entries[i].dispatchedAt == nil
            && observed.phase == .quotaBlocked && observed.isCurrent
            && observed.turnID == next.entries[i].failedTurnID {
            let old = next.entries[i]
            next.entries[i] = Entry(id: UUID(), threadID: threadID, failedTurnID: old.failedTurnID,
                accountID: accountID, title: observed.title, failureAt: old.failureAt,
                revision: observed.revision, nextCheckAt: self.now(), detail: "已重新确认守候",
                requiresObservedBlock: old.requiresObservedBlock)
        }
        _ = self.commit(next)
    }

    func unwatch(threadID: String) {
        guard self.acquireLease() else { return }
        var next = self.state
        next.watchedThreads.removeValue(forKey: threadID)
        for i in next.entries.indices where next.entries[i].threadID == threadID && next.entries[i].status.canCancel {
            next.entries[i].status = .cancelled
            next.entries[i].detail = "已取消守候"
        }
        _ = self.commit(next)
    }

    func refreshThreads() async {
        do {
            let values = try await self.list(self.now().addingTimeInterval(-172_800), Set(self.state.watchedThreads.keys))
            self.recentThreads = values.filter { Self.supports($0) && $0.phase != .archived }
        } catch { self.errorMessage = "无法读取最近的桌面线程" }
    }

    private static func supports(_ observation: Observation) -> Bool {
        !observation.isSubagent && observation.originator == "Codex Desktop"
            && ["openai", "codexbar.openai-oauth"].contains(observation.modelProvider ?? "")
    }

    func start() {
        guard self.loop == nil else { return }
        self.loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break }
            }
        }
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.checkNow() } }
    }

    func stop() {
        self.generation += 1
        self.loop?.cancel()
        self.loop = nil
        if let observer = self.wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        self.wakeObserver = nil
        if !self.isChecking { self.releaseLease() }
    }

    func checkNow() async {
        guard !self.isChecking, !self.storageFailed,
              self.state.enabled || self.state.entries.contains(where: { $0.status.wasDispatched }),
              self.acquireLease() else { return }
        self.isChecking = true
        let generation = self.generation
        defer {
            self.isChecking = false
            if self.loop == nil { self.releaseLease() }
        }
        let now = self.now()
        if case let .unavailable(reason) = self.bridge.capability() { self.capabilityMessage = reason }
        else { self.capabilityMessage = nil }
        do {
            let pendingIDs = self.state.entries.filter { $0.status.canCancel || $0.status.wasDispatched }.map(\.threadID)
            let trackedIDs = Set(pendingIDs).union(self.state.watchedThreads.keys)
            // 常驻服务只追踪守候中的线程和近期变化，不反复扫描开启以来的全部历史。
            let since = max(self.state.enabledAt ?? now, now.addingTimeInterval(-60))
            let observations = try await self.list(since, trackedIDs)
            guard generation == self.generation, !Task.isCancelled else { return }
            self.reconcile(observations, now: now)
            guard !self.storageFailed, self.state.enabled, let accountID = self.state.accountID else { return }
            guard self.identityIsValid(accountID) else {
                // 身份变更必须重新开启；恢复成原账号也不自动撤销这次停止。
                self.configure(enabled: false, accountID: accountID)
                self.errorMessage = "账号或连接方式已变化，守候已停止。确认桌面账号后重新开启。"
                return
            }
            guard self.capabilityMessage == nil else { return }
            // 每次只放行一条，避免同账号的多个线程同时重试。
            guard let entry = self.state.entries.first(where: {
                ($0.status == .waiting || $0.status == .needsAttention) && $0.nextCheckAt <= now
                    && self.state.watchedThreads[$0.threadID] == $0.accountID
            }) else { return }
            try await self.attempt(entry, generation: generation)
        } catch {
            self.errorMessage = "暂时无法确认线程或额度状态，稍后重新检查。"
        }
    }

    private func reconcile(_ observations: [Observation], now: Date) {
        var next = self.state
        for observation in observations {
            for i in next.entries.indices where next.entries[i].threadID == observation.threadID {
                let entry = next.entries[i]
                guard entry.status.canCancel || entry.status.wasDispatched else { continue }
                guard observation.isCurrent else { continue }
                if entry.status.wasDispatched,
                   observation.continuationOperationID?.lowercased() == entry.id.uuidString.lowercased(),
                   observation.turnID != entry.failedTurnID {
                    if observation.phase == .interrupted {
                        next.entries[i].status = .cancelled
                        next.entries[i].detail = "续跑后已被手动停止"
                    } else if observation.phase == .quotaBlocked || observation.phase == .failed {
                        next.entries[i].status = .uncertain
                        next.entries[i].detail = "续跑已收到，但再次失败；请查看线程"
                    } else if observation.phase == .inProgress || observation.phase == .completed {
                        next.entries[i].status = .resumed
                        next.entries[i].detail = "已确认原线程继续运行"
                    }
                } else if entry.status.canCancel,
                          observation.turnID != entry.failedTurnID || observation.phase != .quotaBlocked || observation.revision != entry.revision {
                    next.entries[i].status = .cancelled
                    next.entries[i].detail = "线程已变化或停止，已取消守候"
                } else if entry.status == .dispatching {
                    next.entries[i].status = .uncertain
                    next.entries[i].detail = "上次发送结果未确认，请查看原线程；不会重复发送"
                }
            }
            guard next.enabled, let enabledAt = next.enabledAt, let accountID = next.accountID,
                  observation.isCurrent, observation.phase == .quotaBlocked,
                  Self.supports(observation),
                  observation.queuedMessageCount == 0,
                  let turnID = observation.turnID, let failedAt = observation.quotaFailureAt,
                  (failedAt >= enabledAt || next.watchedThreads[observation.threadID] == accountID),
                  !next.entries.contains(where: { $0.threadID == observation.threadID && $0.failedTurnID == turnID }) else { continue }
            var entry = Entry(id: UUID(), threadID: observation.threadID, failedTurnID: turnID,
                accountID: accountID, title: observation.title, failureAt: failedAt,
                revision: observation.revision, nextCheckAt: now)
            entry.requiresObservedBlock = observation.continuationOperationID != nil && !observation.hasAgentProgress
            if next.watchedThreads[observation.threadID] != accountID {
                entry.status = .needsAttention
                entry.detail = "请先确认此线程使用所选账号，再开启守候"
            }
            next.entries.append(entry)
        }
        if next != self.state { _ = self.commit(next) }
    }

    private func attempt(_ entry: Entry, generation: Int) async throws {
        guard let before = try await self.read(entry.threadID), self.canSend(entry, observation: before, generation: generation) else {
            self.deferEntry(entry.id)
            return
        }
        let decision: CodexQuotaResumeQuota.Decision
        do { decision = try await self.quota(entry.accountID, before.model) }
        catch {
            self.update(entry.id) { $0.nextCheckAt = self.now().addingTimeInterval(60); $0.detail = "额度查询失败，稍后重试" }
            return
        }
        guard generation == self.generation, !Task.isCancelled,
              self.state.entries.first(where: { $0.id == entry.id })?.status.canCancel == true else { return }
        switch decision {
        case let .blocked(nextCheckAt):
            self.update(entry.id) {
                $0.status = .waiting; $0.nextCheckAt = nextCheckAt; $0.detail = "等待额度恢复"; $0.requiresObservedBlock = false
            }
        case let .unavailable(reason):
            self.update(entry.id) { $0.status = .needsAttention; $0.nextCheckAt = self.now().addingTimeInterval(60); $0.detail = reason }
        case .allowed:
            if entry.requiresObservedBlock {
                self.update(entry.id) {
                    $0.status = .needsAttention; $0.nextCheckAt = self.now().addingTimeInterval(60)
                    $0.detail = "上次恢复仍报额度错误，等待服务端确认新的额度周期"
                }
                return
            }
            // 网络查询期间用户可能已经停止、续跑、归档或入队，发送前重新读取。
            guard let latest = try await self.read(entry.threadID),
                  self.canSend(entry, observation: latest, generation: generation),
                  latest.revision == before.revision else {
                self.deferEntry(entry.id)
                return
            }
            guard self.update(entry.id, mutate: {
                $0.status = .dispatching; $0.dispatchedAt = self.now(); $0.detail = "正在请求原线程继续"
            }) else { return }
            let outcome = await self.bridge.enqueue(threadID: entry.threadID, operationID: entry.id) { [weak self] in
                guard let self else { return false }
                return generation == self.generation && self.state.enabled && !self.storageFailed
                    && self.state.watchedThreads[entry.threadID] == entry.accountID
                    && self.state.entries.first(where: { $0.id == entry.id })?.status == .dispatching
                    && self.identityIsValid(entry.accountID)
            }
            switch outcome {
            case let .queued(receipt):
                self.update(entry.id) { $0.status = .queued; $0.receipt = receipt; $0.detail = "已入队，等待原线程实际运行" }
            case let .notDispatched(reason):
                self.update(entry.id) {
                    $0.status = generation == self.generation && self.state.enabled ? .waiting : .cancelled
                    $0.nextCheckAt = self.now().addingTimeInterval(60); $0.detail = reason
                }
            case let .uncertain(reason):
                self.update(entry.id) { $0.status = .uncertain; $0.detail = reason }
            }
        }
    }

    private func deferEntry(_ id: UUID) {
        guard self.state.entries.first(where: { $0.id == id })?.status.canCancel == true else { return }
        self.update(id) { $0.nextCheckAt = self.now().addingTimeInterval(60); $0.detail = "线程状态有变化，等待重新检查" }
    }

    private func canSend(_ entry: Entry, observation: Observation, generation: Int) -> Bool {
        guard generation == self.generation, !Task.isCancelled, self.state.enabled,
              self.state.accountID == entry.accountID, self.identityIsValid(entry.accountID),
              self.state.watchedThreads[entry.threadID] == entry.accountID,
              self.state.entries.first(where: { $0.id == entry.id })?.status.canCancel == true,
              observation.threadID == entry.threadID, observation.turnID == entry.failedTurnID,
              observation.phase == .quotaBlocked, observation.isCurrent,
              observation.queuedMessageCount == 0, Self.supports(observation) else { return false }
        return true
    }

    @discardableResult
    private func update(_ id: UUID, mutate: (inout Entry) -> Void) -> Bool {
        var next = self.state
        guard let index = next.entries.firstIndex(where: { $0.id == id }) else { return false }
        mutate(&next.entries[index])
        return self.commit(next)
    }

    private func commit(_ next: State) -> Bool {
        guard !self.storageFailed, self.acquireLease() else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try CodexPaths.writeSecureFile(encoder.encode(next), to: self.storageURL)
            self.state = next
            self.errorMessage = nil
            return true
        } catch {
            self.storageFailed = true
            self.errorMessage = "无法保存守候记录，自动续跑已停止，未确认的请求不会重发。"
            return false
        }
    }

    private func acquireLease() -> Bool {
        if self.lockDescriptor >= 0 { return true }
        do { try FileManager.default.createDirectory(at: self.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { self.errorMessage = "无法创建守候记录目录"; return false }
        let descriptor = Darwin.open(self.storageURL.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { self.errorMessage = "无法锁定守候记录"; return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            self.errorMessage = "另一个 Codexbar 正在管理自动续跑"
            return false
        }
        self.lockDescriptor = descriptor
        // 可能在另一个实例运行前就创建了本对象；拿到锁后必须重新读盘。
        if FileManager.default.fileExists(atPath: self.storageURL.path) {
            do {
                let loaded = try JSONDecoder().decode(State.self, from: Data(contentsOf: self.storageURL))
                guard loaded.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                self.state = loaded
            } catch {
                self.storageFailed = true
                self.errorMessage = "守候记录无法读取，自动续跑已停止。原文件已保留。"
                self.releaseLease()
                return false
            }
        }
        return true
    }

    private func releaseLease() {
        if self.lockDescriptor >= 0 { flock(self.lockDescriptor, LOCK_UN); close(self.lockDescriptor); self.lockDescriptor = -1 }
    }
}
