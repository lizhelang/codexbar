# Issue #45 本地成本增量索引设计

## 目标

修复 Cost 面板静默显示陈旧或全零数据、人工刷新请求被丢弃、超大 JSONL 反复整文件扫描，以及汇总路径持续遍历完整事件账本的问题。

本设计采用已经确认的渐进式 C+B：以 SQLite WAL 建立可断点恢复的成本索引，同时保留现有 JSON 账本作为迁移期 last-known-good 与回退来源；扫描行为采用 per-file byte offset、预算分片、最近数据优先和独立进度状态。

## 已确认根因

- `MenuBarRefreshOrigin.menuOpen` 不刷新 session cache，旧 ledger 缺少自动追赶机制。
- `TokenStore` 用单个布尔值拒绝并发成本刷新，运行中的轻量刷新会静默丢弃之后的人工深刷新。
- 变化 JSONL 只按 size/mtime 判定，随后从 byte 0 重新解析；本机一次积压需要重读约 5.35 GiB。
- session cache 与 event ledger 是 58 MB / 62 MB 的整体 JSON，任一变化都会触发整体编码和原子替换。
- 汇总会 materialize、排序并折叠全部事件，打开菜单也可能消耗显著 CPU。
- Cost UI 没有独立的扫描状态；OAuth spinner 与错误提示不能代表本地成本扫描生命周期。
- `LocalCostSummary.updatedAt` 代表重新计算时间，不代表原始 JSONL 已扫描到该时刻。

## 架构决策

### 1. SQLite WAL 成本索引

新增独立的 `cost-usage.sqlite`，由单写者协调器持有写连接，UI 和诊断使用只读 WAL snapshot。

核心数据：

- `files`：规范化路径、稳定文件标识、mtime、size、parsed byte offset、边界 anchor hash、parser state、scan complete、最后成功时间；
- `events`：稳定 event key、file/session、timestamp、model、service tier、input/cached/output、turn、source；
- `file_day_aggregates`：每个文件按 day/model/tier/source/rate class 聚合的 token 基数；
- `day_aggregates`：全局按 day/model/tier/source/rate class 聚合；
- `scan_metadata`：扫描范围、总字节、已处理字节、总文件、已完成文件、最后成功原始扫描时间、最新 usage event、错误与迁移状态；
- `fork_lineage` / `accumulators`：父子关系、继承基线、累计高水位及 replay 去重状态。

金额仍由当前价格表从 token 基数派生；价格变化只重算聚合，不重读 JSONL。

### 2. 可恢复的追加量扫描

- 文件未变化：直接复用索引；
- 同一稳定文件且 size 增长、anchor 一致：seek 到 `parsedBytes`，只读取新增完整行；
- 半行：保留边界，不提前推进 cursor；
- 截断、替换、identity 变化或 anchor 失配：仅重建该文件及受影响的 fork descendant；
- 解析状态持久化 model、tier、turn、usage high-water、fork/subagent replay 状态；
- 写入事件、聚合、cursor 和 scan metadata 必须在事务中原子提交；
- 扫描采用 byte/time budget，后台普通模式小批运行，人工加速模式扩大预算；
- 冷启动和大积压优先最近日期，使 Today/30d 先可用，Lifetime 在后台继续追赶。

### 3. 渐进迁移与回退

- 不删除原始 JSONL、旧 `cost-session-cache.json`、`cost-event-ledger.json` 或已有摘要；
- SQLite 首次建立期间继续展示 last-known-good；未知状态显示 `—`，不得伪装为真实零；
- 新索引建立后，用固定 fixtures 和真实本机汇总对比 Today/30d/Lifetime、每日、模型、tier 和 fork/subagent 结果；
- 对账通过后切换 UI 主读 SQLite，旧 JSON 保留为回退；
- 稳定后停止旧 JSON 写入，但删除旧派生文件不属于本 issue 的必要步骤。

### 4. 刷新协调与 UI

新增 store 级 `LocalCostRefreshCoordinator`，请求强度为：

`snapshotOnly < incremental < rebuildAll`

在途任务收到新请求时合并为最高强度；人工请求不得被自动请求覆盖或丢弃。

Cost 卡片独立展示：

- 当前 last-known-good 数字；
- 首次索引时的未知态；
- processed bytes / total bytes 与 completed files / total files；
- 最新原始 usage event、最后成功扫描时间和 stale 状态；
- partial / failed 状态及重试入口；
- 最近 30 个自然日图表，缺失日期补零。

OAuth/WHAM 刷新继续使用自己的 spinner 与错误提示，不再承担 Cost 状态表达。

## 正确性边界

- 保留 cached input 是 input 子集的计数规则；
- 保留单事件长上下文加价、priority/fast tier、自定义价格覆盖和未知模型 token 可见性；
- 保留 fork/subagent replay、高水位与重复 session ID 处理；
- 本地 Cost 仍是本机日志估算，不承诺按 OpenAI 账号精确拆分，也不冒充官方账单。

## 验证

- 先增加失败测试：人工刷新升级不丢失、last-good 不归零、append 只读尾部、半行、截断、替换、归档移动、fork baseline 失效、崩溃事务恢复、价格重算、30 个自然日；
- 针对性 XCTest、完整 XCTest、`xcodebuild analyze`、`git diff --check`；
- Debug 与优化 Release 分别验证，Release 必须不链接 `codexbar.debug.dylib`；
- 在本机 14.7 GiB JSONL 上完成冷启动 catch-up 与热增量基准，确认 Today 恢复、二次刷新只处理新增尾部、UI 可响应、CPU 最终恢复空闲；
- 生成本地安装包，安装 `/Applications/codexbar.app`，清理构建/安装残留并确认 Launch Services 仅剩目标副本；
- 创建 PR、独立代码审查、修正高优先级问题、合并关闭 Issue #45。

