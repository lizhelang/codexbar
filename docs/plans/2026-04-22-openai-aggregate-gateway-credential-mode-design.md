# OpenAI Aggregate Gateway Credential Mode Design

Date: 2026-04-22

## Summary

为 `codexbar` 的现有 OpenAI `aggregateGateway` 模式新增一个子设置 `gatewayCredentialMode`：

- `oauth_passthrough`
- `local_api_key`

目标是在不新增第三个顶层 usage mode、不改变 aggregate 既有路由语义的前提下，让 Codex Desktop / CLI 在 `local_api_key` 模式下只在 `~/.codex/auth.json` 中持有本地 fake API key，并继续通过本机 localhost OpenAI gateway 路由到真实 OpenAI OAuth 账号池。

## Why This Shape

当前仓库已经证明三件关键事实：

1. aggregate gateway 内核已经稳定支持 `GET /v1/responses` websocket upgrade、`POST /v1/responses` 与 `POST /v1/responses/compact`，相关测试已通过。
2. Codex 客户端会真实把 `auth.json` 中的 `OPENAI_API_KEY` 作为 `Authorization: Bearer ...` 发往 `ws://127.0.0.1:<port>/v1/responses`。
3. `CodexBarOpenAIAccountUsageMode` 只有 `switchAccount` / `aggregateGateway` 两个顶层 mode，旧配置对未知枚举会 lossy 回退默认值，因此不适合新增第三个顶层 mode。

因此，fake key 能力应当作为 `aggregateGateway` 的子策略，而不是新的产品主模式。

## Chosen Direction

在 `CodexBarOpenAISettings` 下新增：

- `gatewayCredentialMode = oauth_passthrough | local_api_key`

仅当 `accountUsageMode == .aggregateGateway` 时生效。

### `oauth_passthrough`

保持当前 aggregate 行为：

- `config.toml` 继续写 localhost `openai_base_url`
- `auth.json` 继续写真实 ChatGPT OAuth token 包

### `local_api_key`

新增行为：

- `config.toml` 继续写 localhost `openai_base_url`
- `auth.json` 仅写 fake `OPENAI_API_KEY`
- 真实 OpenAI OAuth token 不再写入 `~/.codex/auth.json`
- 真实账号凭证仅由 codexbar 内部账号池与 gateway 上游链路持有

## Security Boundary

Phase 1 采用双保险：

1. listener 绑定层
   - 使用 `NWParameters.requiredLocalEndpoint = 127.0.0.1:<port>`
   - 用 `NWListener(using: params)` 创建 listener

2. 连接校验层
   - 对 `NWConnection.currentPath?.remoteEndpoint` 做 loopback-only 校验
   - 无法确认来源或非 loopback 时拒绝处理

3. 鉴权层
   - `local_api_key` 模式下校验 inbound `Authorization: Bearer <fake key>`
   - outbound 上游请求继续使用真实 OAuth token

## Fake Key Storage

Phase 1 不引入 Keychain。

fake key 先存放在：

- `~/.codexbar/openai-gateway/credential.json`

理由：

1. 当前仓库已有 `openai-gateway` 状态目录
2. `state.json` 已被 aggregate lease store 使用，不能直接复用
3. `CodexPaths.writeSecureFile(...)` 已保证 `0600` 权限
4. fake key 与用户主配置分层，便于 Phase 2 迁移到 Keychain

## UI / UX

主模式仍只有：

- `手动切换`
- `聚合网关`

当用户选择 `聚合网关` 时，设置页再显示一个子选项：

- `兼容模式（OAuth 透传）`
- `本地 API Key 模式（推荐）`

这不会改变 aggregate 在产品层已经存在的“汇总/路由模式”语义。

## Phase 1

1. 在 `CodexBarOpenAISettings` 新增 `gatewayCredentialMode`
2. 让该字段贯穿：
   - `SettingsWindowDraft`
   - `OpenAIAccountSettingsUpdate`
   - `SettingsSaveRequestApplier`
   - `TokenStore.shouldSyncCodexAfterSavingSettings(...)`
3. `CodexSyncService` 在 `aggregate + local_api_key` 下仅写 fake key 到 `auth.json`
4. 在 `~/.codexbar/openai-gateway/credential.json` 持久化稳定 fake key
5. 扩展 gateway runtime state contract，让运行态拿到 `gatewayCredentialMode` 与 fake key
6. `OpenAIAccountGatewayService` 增加统一 ingress auth guard
7. `OpenAIAccountGatewayService` 改成 loopback-only listener + 连接来源校验
8. 扩展现有 config / settings / sync / gateway / lifecycle 测试

## Phase 2

1. Keychain 持久化
2. fake key 迁移与轮换策略
3. 旧版本丢失新子字段时的显式提示
4. 更多运行态诊断与安全硬化

## Acceptance Criteria

1. `aggregate + local_api_key` 下，`~/.codex/auth.json` 不再出现真实 OAuth token 包
2. Codex Desktop / CLI 继续可通过 localhost OpenAI gateway 工作
3. aggregate sticky / failover / lease / compact / routed-account presentation 不回归
4. gateway 仅接受 loopback + 正确 fake key 的访问
5. 仅切换 `gatewayCredentialMode` 也会触发 `auth.json` / `config.toml` 重写

## Residual Risk

Phase 1 只承诺“真实 OAuth token 不再写入 `~/.codex/auth.json`”。
它不承诺“本机磁盘完全不再持有真实 token”，因为真实账号凭证仍会保留在 codexbar 自己的本地账号池 / 配置中。更强的主机级凭证隔离留到后续 Keychain 迁移阶段。

## Planning Artifacts

- [共识总稿](/Users/lzl/FILE/github/codexbar/.omx/plans/ralplan-openai-aggregate-gateway-credential-mode-20260422.md)
- [PRD](/Users/lzl/FILE/github/codexbar/.omx/plans/prd-openai-aggregate-gateway-credential-mode.md)
- [Test Spec](/Users/lzl/FILE/github/codexbar/.omx/plans/test-spec-openai-aggregate-gateway-credential-mode.md)
- [执行前检查单](/Users/lzl/FILE/github/codexbar/.omx/plans/openai-aggregate-gateway-credential-mode-exec-checklist-20260422.md)
- [执行 Prompt 草稿](/Users/lzl/FILE/github/codexbar/.omx/drafts/openai-aggregate-gateway-credential-mode-exec-prompt-20260422.md)
