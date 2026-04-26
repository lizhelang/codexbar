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

    func requestRefresh(
        now: Date = Date(),
        load: @escaping Loader,
        apply: @escaping Deliver
    ) {
        func start(_ request: PendingRequest) {
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
                        start(pendingRequest)
                    }
                }
            }
        }

        let request = PendingRequest(now: now, load: load, apply: apply)
        if self.isRefreshing {
            self.pendingRequest = request
            return
        }

        start(request)
    }

    func reset() {
        self.generation += 1
        self.pendingRequest = nil
    }
}
