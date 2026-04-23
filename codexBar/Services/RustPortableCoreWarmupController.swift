import Foundation

@MainActor
final class RustPortableCoreWarmupController: LifecycleControlling {
    static let shared = RustPortableCoreWarmupController()

    private init() {}

    private(set) var lastWarmupError: String?

    func start() {
        guard PortableCoreRollbackController.shared.isEnabled else { return }
        let mode = RustPortableCoreAdapter.shared.runtimeMode()
        guard mode != .legacy else { return }
        do {
            try RustPortableCoreAdapter.shared.warmup(buildIfNeeded: false)
            self.lastWarmupError = nil
        } catch {
            self.lastWarmupError = error.localizedDescription
            PortableCoreRollbackController.shared.disable(reason: "warmupFailure")
        }
    }

    func stop() {}
}
