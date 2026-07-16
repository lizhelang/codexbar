# 逐事件计费账本 v4 设计

## 背景

现有本地用量统计保留了 Today、30 Days、Lifetime 和持久化 ledger，但计费事件只保存 session 级模型，无法准确表达同一 session 内的模型切换、turn、处理层级和来源。复杂 fork、subagent 与累计计数器交错时，也缺少足够的事件级证据完成可靠去重。

本设计保留现有 UI、统计口径、手工价格覆盖和 Lifetime 历史能力，在现有 `SessionLogStore` 与 `cost-event-ledger.json` 上渐进升级，不整套引入上游扫描器。

## 目标

- 每个计费事件独立保存模型、turn、service tier 和来源。
- 按事件重新计算金额，修复多模型 session 的统一计价问题。
- 对普通 fork、subagent 和交错累计计数器使用明确且保守的差分规则。
- 保留原始日志已经消失的 Lifetime 历史。
- 自动、原子、幂等地从旧 ledger 升级，不阻塞应用启动。
- 保持 Today、30 Days、Lifetime UI 和外部行为不变。

## 非目标

- 不把本地估算包装成 OpenAI 官方账单。
- 不改变额度、Credits 或账号切换链路。
- 不新增 UI 页面或依赖。
- 不整套复制 steipete/CodexBar 的 `CostUsageScanner`。

## 数据模型

`cost-event-ledger.json` 升级为 v4。每个事件保存：

- `timestamp`
- `usage`：input、cached input、output 的增量
- `modelID`
- `turnID`
- `serviceTier`：`standard`、`priority`、`unknown`
- `source`：`nativeSession`、`fork`、`subagent`、`legacyMigration`
- `costUSD`：仅供无法重新定价的 legacy 事件兜底

session 级 `model` 保留为旧数据迁移和兼容字段，但新事件金额不得依赖它统一计价。

## 扫描状态机

扫描每个 JSONL 文件时维护：当前模型、当前 turn、当前 tier、累计高水位、已经观察的累计快照、session 元数据和父 session 信息。

1. `session_meta` 建立 session、父子关系和来源。
2. 每次 `turn_context` 都更新当前模型和可见 tier。
3. `task_started` 更新当前 turn。
4. `token_count` 按“事件模型、当前 turn 模型、unknown”的顺序归因。
5. 优先使用可靠的 `last_token_usage`；同时用累计高水位限制增量，防止重复计数。
6. 普通 fork 尝试扣除父 session 在分叉时间的累计基线。
7. subagent 视为独立累计来源，不扣父基线。
8. 累计量回落或不同 lineage 交错后进入保守模式，不再把 lineage 间差距当成新增用量。

无法证明增量时，宁可跳过可疑快照并报告不完整，也不静默重复计数。

## 计价规则

- Token 是事实，金额是可重算派生值。
- cached input 是 input 的子集，计算前必须 clamp。
- 长上下文门槛按单个事件判断。
- 使用精确模型 ID 和明确别名，不对未知后缀做宽泛继承。
- `gpt-5.3-codex-spark` 明确为零成本。
- 未知模型保留 Token，金额为零并标记缺少价格。
- 用户手工价格覆盖始终优先，并作为该模型所有 tier 的最终价格。
- 无手工覆盖时，可靠识别的 Priority/Fast turn 使用专用价格；tier 不确定时使用 Standard，不猜测。
- 摘要加载时按当前价格表重新计算历史金额。

## 迁移与容错

- 原始 JSONL 仍存在的 session 全量重建为 v4。
- 原始日志已消失的事件保留并标记为 `legacyMigration`。
- 只有一个 session 完整重建成功后才替换其旧事件。
- ledger 使用临时文件和原子替换；迁移失败保留旧文件。
- 迁移和重复刷新必须幂等。
- 未知模型、未知 tier、缺失时间戳或单个损坏文件不得使整个摘要失败。

## 验证

回归测试覆盖多模型 session、事件模型优先级、tier、Spark、未知模型、cached clamp、长上下文、普通 fork、subagent、累计量交错、live/archived 去重、日志删除后的 Lifetime 保留、v3 到 v4 迁移和幂等性。

验证顺序：针对性测试、完整测试套件、真实本机日志只读对比、Release 构建、安装后进程与唯一 bundle 检查。
