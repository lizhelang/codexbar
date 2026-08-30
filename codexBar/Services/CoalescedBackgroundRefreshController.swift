import Foundation

@MainActor
final class CoalescedBackgroundRefreshController<Result> {
    typealias Loader = @Sendable (Date) -> Result
    typealias Deliver = @MainActor (Result) -> Void

    private struct PendingRequest {
        let now: Date
        let load: Loader
        let apply: Deliver
    }

    private let queue: DispatchQueue
    private var generation = 0
    private var isRefreshing = false
    private var pendingRequest: PendingRequest?

    init(queue: DispatchQueue = .global(qos: .utility)) {
        self.queue = queue
    }

    // Swift 6.3.3 在 x86_64 Release 下对本类合成 deinit 跑 EarlyPerfInliner 时会崩溃
    // (isCallerAndCalleeLayoutConstraintsCompatible 段错误),显式声明并关闭优化以绕开。
    @_optimize(none)
    deinit {}

    func requestRefresh(
        now: Date = Date(),
        load: @escaping Loader,
        apply: @escaping Deliver
    ) {
        let request = PendingRequest(now: now, load: load, apply: apply)
        if self.isRefreshing {
            self.pendingRequest = request
            return
        }

        self.start(request)
    }

    private func start(_ request: PendingRequest) {
        self.isRefreshing = true
        let generation = self.generation
        self.queue.async {
            let result = request.load(request.now)

            Task { @MainActor [weak self] in
                guard let self else { return }

                if generation == self.generation {
                    request.apply(result)
                }

                self.isRefreshing = false
                if let pendingRequest = self.pendingRequest {
                    self.pendingRequest = nil
                    self.start(pendingRequest)
                }
            }
        }
    }

    func reset() {
        self.generation += 1
        self.pendingRequest = nil
    }
}
