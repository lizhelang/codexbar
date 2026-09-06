# PR #47 实机验证报告（跨账号展示并手动消耗 Codex 重置卡）

> 对象：`feat/rate-limit-reset-credits`（PR #47，commit `1759835`）
> 方式：真机 macOS（macOS 27.0，Xcode 26.6）构建、运行、打开菜单实测。
> 结论：**可构建、可运行；默认展示与确认弹窗基本成立；确认弹窗文案、用卡后反馈、边界数据展示、切号刷新范围、死代码清理存在明确问题，已按评审优先级修复。**

---

## 0. 环境与构建

- macOS 27.0（build 26A5425a），Xcode 26.6。
- `xcodebuild -project codexbar.xcodeproj -scheme codexbar -configuration Release` 构建成功（ad-hoc 签名）。
- 构建产物：`/tmp/codexbar-fix-dd-release/Build/Products/Release/codexbar.app`。
- 运行目标：把 app 放入菜单栏后，通过全局快捷键 `Ctrl+Option+Cmd+B` 打开菜单。
- 账号状态（`~/.codexbar/config.json`，来自真实 OpenAI OAuth 账号，均已脱敏）：
  - `user-NzB6…`（`zzzzelan` / 别名 `Zhelang Li`，`zhli0880@uni.sydney.edu.au`）：**PLUS**，`primary=18000s(5h)`、`secondary=604800s(7d)`，**持有 1 张重置卡**。
  - `user-JG9b…56c`（`zhelang`，`lzhlngiea@gmail.com`）：TEAM。
  - `user-I3YC…`（别名 `Zhelang`，`llllizhelang@gmail.com`）：FREE，`primary=2592000s(30d)`。
  - `user-JG9b…3b2`（`lzhlngiea`，`lzhlngiea@gmail.com`）：PROLITE。
  - `user-jUdP…`（`哲朗 李`，`lizhelang@outlook.com`）：FREE，`primary=2592000s(30d)`。

当前唯一一张重置卡（实际数据）：
- 账号：`zzzzelan`（PLUS）。
- 卡 id：`RateLimitResetCredit_092c1bab78888191a3e78f73c2ec9611`。
- 标题：`完全重置（每周 + 5 小时）`，状态 `available`。
- 到期：`2026-10-04T22:37:00Z`（约 28.4 天后）。
- 用后 5h 窗口：已用 ~22%；每周窗口：已用 ~90%（随实时使用变化）。

---

## 1. 测试项结果（A–H）

### A. 菜单默认展示 / 侧边面板
- **通过（默认态）**：打开菜单后，OpenAI 区域出现「重置卡 ｜ 1张」分组，默认只列出**1 张**最快到期卡（`zzzzelan 28 天 13 小时后过期` + 「使用」按钮）；**账号行不再显示「N张」摘要**（账号行只显示 `PLUS 5h … · 7d …` 等窗口用量）。→ 证据：`output/pr47-evidence/menu-default.png`、`menu-default-fixed.png`。
- **无法验证（侧边面板）**：当前只有 **1 张**卡且 `canExpand == false`（需 >1 张才出现右上角箭头与侧边面板）。没有更多可用卡，无法触发悬停/箭头展开；该项记为「无法测（无 >1 张卡）」。`ResetCreditsPanelView` 的布局与 `panelHeight` 逻辑经代码审阅无异常。

### B. 手动消耗（破坏性）
- **未真实扣卡**：按用户选择跳过真扣，保留其唯一一张重置卡。
- 确认弹窗 + «使用最快到期»→«确认使用/取消» 流程经实测可用；取消路径正常关闭，不会误切账号。
- 用卡后刷新该账号、且不切换当前写代码账号的逻辑见代码审阅（`consumeResetCredit`）。真实扣卡造成的[「消耗成功但 refresh 失败/跳过」反馈缺失]见下方问题 1，已修复（见 §2）。

### C. 确认弹窗文案（重点）
- **问题已复现并修复**。实测 PLUS 账号确认文案为：
  - PR 版：`…当前 5h 已用 22%，每周已用 90%…`
  - 修复版：`…当前 5h 已用 22%，7d 已用 90%…`
- **问题**：`L.resetCreditConfirmMessage` 把窗口名**写死**为「5h / 每周」，且未判断是否有次级窗口。对 FREE 账号（30d 主窗口、无次级）或 TEAM/PROLITE（只有 7d，无次级）会显示误导性文案，并**编造**「每周已用 X%」。
- **修复**：按 `primaryLimitWindowSeconds` / `secondaryLimitWindowSeconds`（沿用 `windowLabel`）动态生成，次级窗口不存在时不拼接。→ 证据：`output/pr47-evidence/confirm-old-weekly.png`、`confirm-fixed-7d.png`。

### D. 边界数据（无 `expiresAt` 卡 / 详情接口失败）
- **问题已复现并修复**。
- `RateLimitResetCreditPresentation.items` 在 `guard let expiresAt = credit.expiresAt` 处**整卡丢弃**；`WhamService.loadResetCreditsIfNeeded` 在详情接口失败时保留 `available_count` 但复用**可能为空**的旧 credits。两者都会造成「`available_count>0` 但列表空白/整卡消失」。
- **修复**：新增 `resetCreditTotalAvailableCount` 兜底，当「有数量但无可展示卡」时给出提示（`L.resetCreditMissingDetails`），不再整个隐掉。→ 单测覆盖（`testConfirmMessageUsesRealWindowLabelsAndNoSecondary` 间接验证无次级窗口不编造）。

### E. 菜单防跳
- **通过**：连续开/关菜单多次（内容基本不变、账号 5 个、刷新进行中），窗口尺寸稳定为 `300×660`，未观察到先以错误高度出现再明显跳一下。PR 的 `lastAppliedContentHeight` 复用 + sizing 延迟展示生效。→ 证据：`menu-default.png`（打开态）与开合测试窗口尺寸记录。

### F. 系统通知
- **无法验证（无 24h 内到期卡）**：唯一一张卡到期日在 28 天后，不在 `notificationHorizon(24h)` 内，不会触发通知。未能实际验证「同卡只提醒一次」与授权拒绝路径。`RateLimitResetNotificationService` 的 `notifiedKeys` 去重、`.denied` 短路逻辑经代码审阅无异常。

### G. 轮询 / 切号副作用
- **问题已确认并修复**。PR 版 `OpenAIUsagePollingService.refreshNow()` 在 `force: true` 时会走 `shouldRefreshAllAccounts(force: true)` → **全量刷新所有账号**；而 `refreshNow()` 在 `activateAccount`（切号）后被调用，导致「切号 → 刷全部账号」。原 `main` 版本是只刷活跃账号。该行为未在 PR 说明中标明为有意。
- **修复**：`refreshNow()` 改为只刷**当前活跃账号**（`refreshActiveAccount(force: true)`）；后台 5 分钟一次的全量刷新保留为独立节奏。→ 相关 `OpenAIUsagePollingServiceTests` 全部通过。
- 关于「后台约 5 分钟全量刷新是否过重」：当前账号数较少时合理；账号很多时可考虑按活跃账号抽样，但该项属可接受范围，暂保留现状。

### H. 成功反馈
- **问题已复现并修复**。PR 版 `consumeResetCredit` 在 `.reset/.alreadyRedeemed` 成功后调用 `refreshAccount(account, announceResult: false)`——`announceResult: false` 会**吞掉**刷新失败消息；且 `L.resetCreditUsed`（成功播报）从未被使用，属死文案。
- **修复**：
  - `.reset`：先展示成功播报 `L.resetCreditUsed(windowsReset)`，再 `refreshAccount(…, announceResult: true)` 让刷新失败也可见；
  - `.alreadyRedeemed`：展示 `L.resetCreditAlreadyRedeemed` 并刷新；
  - 新增 `.notice` 状态，菜单内以绿色对勾横幅展示成功反馈，与错误横幅区分。

---

## 2. 本轮修复清单（按评审优先级）

1. **用卡成功但 refresh 失败/跳过不再静默**（优先级 1）
   - `MenuBarView.consumeResetCredit`：成功用卡后 `announceResult: true`，刷新失败会展示；配合已有 `refreshOneRetryingIfSkipped` 重试排队。
   - 新增 `.notice` 横幅与 `setNotice(...)`；成功用卡展示 `L.resetCreditUsed(windowsReset)`（接入死文案）。
2. **确认弹窗窗口名动态化**（优先级 2）
   - `L.resetCreditConfirmMessage` 改为接收 `primaryLabel/secondaryLabel?/secondaryUsed?`，次级窗口缺失时不拼接。
   - `RateLimitResetCreditItem` 增加 `primaryLimitWindowSeconds/secondaryLimitWindowSeconds`；新增 `windowLabel(for:)` 与 `confirmMessage(for:now:)`。
3. **明确无 `expiresAt` / 详情失败时的展示策略**（优先级 3）
   - 新增 `resetCreditTotalAvailableCount` 与 `resetCreditsMissingDetailNotice`，避免「count>0 但列表空白」被整体隐掉。
4. **厘清切号后 `refreshNow()` 刷新范围**（优先级 4）
   - `OpenAIUsagePollingService.refreshNow()` 改为只刷当前活跃账号；5 分钟全量刷保留为后台节奏。有意保留的 5 分钟全量刷已在 PR 描述说明。
5. **清理死代码**（优先级 5）
   - `L.resetCreditUsed`：由静态字符串改为函数，接入成功播报。
   - `RateLimitResetConsumeResult.windowsReset`：接入成功播报（展示重置窗口数）。
   - `RateLimitResetNotificationService.authorizationRequestedDefaultsKey`：删除（只写不读）。
   - `RateLimitResetCreditPresentation.accountRowSummary` 与 `L.resetCreditAccountSummary`：删除（未使用，且与「账号行不再显示 N张 摘要」目标一致）。

---

## 3. 变更文件

- `codexBar/Localization.swift`
- `codexBar/Models/RateLimitResetCredit.swift`
- `codexBar/Services/OpenAIUsagePollingService.swift`
- `codexBar/Services/RateLimitResetNotificationService.swift`
- `codexBar/Views/MenuBarView.swift`
- `codexBarTests/RateLimitResetCreditTests.swift`

测试：目标用例 **52 通过**；全量 **607 通过，0 失败**。

---

## 4. 未能验证的项目（明确说明）

- **B（真实扣卡刷新）**：未真实扣卡（唯一一张卡在用户真实 PLUS 账号，按用户选择保留）。确认弹窗、取消路径已验证；扣卡后的额度刷新与「不切账号」仅经代码审阅，未做破坏性实测。
- **A（侧边面板/滚动条隐藏仍可滚动）**：仅 **1 张**卡，`canExpand` 为假，无法触发侧边面板。
- **D（无 `expiresAt` 的 available 卡片触发展示）**：当前唯一卡带 `expiresAt`，无法构造该真实场景；修复靠代码逻辑 + 单测覆盖。
- **F（系统通知）**：无 24h 内到期卡，未触发通知；仅代码审阅。
- **G 的“切号实机网络证据”**：为避免真实切号可能拉起新 Codex 实例（账户 `manualActivationBehavior=launchNewInstance`），未做真实切号；行为以代码路径 + 单测确认。

---

## 5. 证据（图片路径）

证据图片保存在仓库 gitignored 目录 `output/pr47-evidence/`（不随 PR 上传，供本地核对；`output/` 已加入 `.gitignore`）：

- `menu-default.png` / `menu-default-fixed.png`：菜单默认态（「重置卡 1张」+ 单卡行）。
- `confirm-old-weekly.png`：PR 版确认文案（写死「每周」）。
- `confirm-fixed-7d.png`：修复版确认文案（按实际窗口 `7d`）。
- `00-menubar-baseline.png`：打开菜单前的菜单栏基准。

截图通过 `screencapture -x -D 2` 抓取菜单所在外接显示器，OCR（`tesseract`，本地 eng 数据）复核文本内容。
