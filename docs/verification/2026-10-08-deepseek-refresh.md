# DeepSeek 官方余额刷新修复

日期：2026-10-08（Australia/Sydney）。本次为 2.0.1 发布后的本地修复，不修改已发布的 GitHub 标签或安装包。

## 根因与运行态证据

- 当前机器原来选中的是 `.dshSnapshot` 连接；刷新只重读 `provider-snapshots.json`，不会请求账户服务。
- 旧余额的原始观测时间为 2026-09-26。重读文件没有新余额可读取，因此它会一直显示旧金额与旧时间。
- DSH 根目录没有声明官方地址的 `.env`。自动发现的安全检查不会把未绑定地址的私有 Key 当作官方账户凭据；本次由用户明确确认该账户属于 DeepSeek 官方后，添加显式连接路径。
- 现场只检查日志类型、时间和用量数值：最新 v4 日志有采集器已支持的 `assistant/message.data.usage`。已有历史缓存成功读到 2026-10-08 04:57:34 UTC 的用量，05:02:01 UTC 完成扫描，含 3,599 条记录。当前余额陈旧不能归因于新格式漏读。
- 本机安装的 `@linxin666/dsh-usage` 0.3.17 中，余额适配器固定请求 `ds.zooe.cc`；失败时保留旧余额并写 `balanceError`。本次没有调用该插件刷新端点，也没有修改 DSH 插件或凭据文件。

## 实现

- 用户明确选择连接 DSH 的官方账户后，通过现有受限解析器读取 owner-private、非符号链接的 DSH Key，并在验证成功后交给正常连接存储保存。
- 官方余额请求固定为 `https://api.deepseek.com/user/balance`，拒绝重定向，绕过 HTTP 缓存。没有向第三方地址尝试发送官方 Key。
- 成功连接自动选中实时结果；未明确选择来源时，官方 API 连接优先于旧快照。用户显式选择的快照仍保留。
- 手动官方连接存在时仍同步自动快照来源；过时来源记录可以退出列表，不会覆盖选中的实时账户。
- 网络失败或查询直接抛错时，保留上次成功的余额、来源和成功时间，显示失败说明并持久保存。新增连接验证失败不保存凭据。
- 快照余额有独立来源标记、原始时间和“非实时”说明，操作称为“重读快照”。DSH 已知余额刷新失败也会显示失败；错误原文不会显示或进入缓存。
- DSH `credential` 的 `env`、`api-key`、`oauth`、`none` 是种类，不能作为账号身份合并不同来源。
- 同版本的历史日志选择更新的修改时间；时间一致时优先压缩副本。连续新增 zstd 帧和新 v4 会话会更新用量，避免重复累加旧帧。

## 参考与数据边界

- [DeepSeek 官方余额 API](https://api-docs.deepseek.com/api/get-user-balance/) 提供当前余额、赠金和充值余额，没有模型或日期的历史账单字段。
- [Token Monitor 官方余额读取](https://github.com/Javis603/token-monitor/blob/5d2db368d8313415763860d594de00e46a663418/src/shared/providers/deepseek/limits.js)：直接请求官方接口；手动刷新分别驱动额度和历史采集。其余额差值历史是观测估算，不能补回首次采样前的账单。
- [QuotaClock 官方余额读取](https://github.com/carey-bk/QuotaClock/blob/dfcc055c728f342aa1d56f334c39990f6615f78e/Sources/QuotaCore/DeepSeekProvider.swift)：实时查询独立于 DSH 本地账本，失败保留旧成功数据。仓库未授予整体开源许可，本次仅参考行为，没有复制代码。
- Codexbar 的 DSH 历史仍来自本机日志，不代表所有设备的官方账户账单。当前采集周期为 90 秒，手动刷新可以强制重读。没有叠加插件账本造成双计，也没有把余额变化伪装成完整官方历史。

## 验证

运行日志保留于 `/private/tmp/codexbar-deepseek-refresh-20261008.yFheZD`。真实账户验证需要显式启用专用 witness；正常测试运行默认跳过，不读取操作员 DSH Key。

- `final-regression.xcresult`：8 个相关测试类共 94 项，88 通过、6 跳过、0 失败。
- 最后补齐来源同步后，`source-migration.xcresult` 再验证官方连接、连接存储与原生账号布局，24 项中 23 通过、1 个未启用的真实账户 witness 跳过、0 失败。
- 6 个常规跳过包括 2 个需要真实凭据明确启用的检查，以及 4 个隔离进程无法公开 SwiftUI 控件树的检查；离屏图像、完整账号名与必需按钮仍有通过证据。
- `official-live.xcresult`：显式启用真实官方账户 witness，首次连接与随后强制刷新均成功。缓存保存的是官方 API 返回值与当前成功查询时间，选中的是手动 `.dshOfficialAPI` 连接。
- 首次编译发现不可变说明字段被修改，已改为构造新快照。首轮图像测试全文 OCR 漏读窄窗口按钮；原图存在该按钮，已让既有分段 OCR 同时校验完整账号名和必需按钮，保留原断言。
- 独立限定复审指出直接抛错也应保留旧余额，已补齐该路径、持久化与回归；复审关闭该问题。

## 本机交付

- Apple clang 的最终 Release 构建成功，`arm64 x86_64` 通用架构。本地构建使用 `CURRENT_PROJECT_VERSION=59`，安装版本为 `2.0.1 (59)`，已发布的 `2.0.1 (58)` 资产与 Git 标签未更改。
- `/Applications/codexbar.app` 严格 ad-hoc 签名校验通过，可执行文件 SHA-256 与已验证候选一致。未宣称 Developer ID 签名或公证。
- 新应用进程已启动。运行态保持 `.dshOfficialAPI` 选中和 `.ready` 状态，05:12:40 UTC 再次成功更新官方余额；快照来源已同步为两条独立来源，没有覆盖实时选择。
- 已注销并移除本次 Debug / Release 的应用、DerivedData 和临时回滚副本。Launch Services 仅剩 `/Applications/codexbar.app`；Spotlight 无索引结果；运行目录中没有残留 `.app`。
- 保留构建日志、测试结果、候选/安装校验元数据与清理记录。此前 CRAP 指标草稿未修改，未创建本次提交或推送。
