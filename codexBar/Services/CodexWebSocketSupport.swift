import Foundation

/// 同步进 Codex 配置的 WebSocket 传输策略。
enum CodexWebSocketSupportDirective: Equatable {
    /// 使用 Codex 对当前提供商的默认传输策略。
    case remove
    case write(Bool)
}

/// 手动设置优先；自动模式不猜测 Codex 进程的代理路径或 WebSocket 能力。
struct CodexWebSocketSupportCoordinator {
    static let live = CodexWebSocketSupportCoordinator()

    func directive(for config: CodexBarConfig, route _: ResolvedCodexRoute) -> CodexWebSocketSupportDirective {
        switch config.openAI.webSocketSupportOverride {
        case .automatic:
            return .remove
        case .enabled:
            return .write(true)
        case .disabled:
            return .write(false)
        }
    }
}
