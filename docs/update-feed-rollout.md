# codexbar 更新检测与 bridge rollout 约定

## 当前运行时语义

- 修复后的客户端运行时直接读取 GitHub Releases 列表。
- 客户端不会盲信 `/releases/latest`；而是扫描 releases 列表，选择**第一个可安装的正式稳定版本**。
- “可安装的正式稳定版本”定义为：
  - `draft == false`
  - `prerelease == false`
  - 至少带一个 `dmg` 或 `zip` 资产
- 当前稳定策略仍是 **guidedDownload**：
  - 启动自动检查
  - 手动检查更新
  - 发现新版后提示
  - 根据架构/格式打开匹配安装包下载链接
- 当前产品**不宣称**已经具备自动替换旧 app 并自动重启的闭环。

## 一次性 bridge 约定

- `release-feed/stable.json` 仅保留这一次 `1.1.8 -> 1.1.9` 的兼容桥接。
- 旧客户端仍只认 feed，因此需要把 `stable.json` 指到重发后的 `1.1.9` 资产。
- 修复后的客户端不再把 `stable.json` 当作运行时真相源。
- bridge 不应演化成长期 fallback；后续版本检测以 GitHub Releases 为准。

## 为什么仍是 guided download

- 仓库当前没有成熟的自动更新引擎接入。
- 当前发布语义仍是“检测 + 引导下载/安装”，不是“自动替换安装”。
- 因此运行时源虽然切到了 GitHub Releases，但交付行为仍保持人工继续下载/安装。

## GitHub Releases 过滤与资产映射

- 列表扫描按 GitHub API 返回顺序进行。
- 遇到以下 release 必须跳过：
  - draft
  - prerelease
  - 不带 `dmg` / `zip` 资产的正式 release
- 资产映射约定：
  - Apple Silicon 优先匹配 `arm64`，其次 `universal`
  - Intel 优先匹配 `x86_64`，其次 `universal`
  - 格式优先级：`dmg` 高于 `zip`
- 若文件名未带显式架构后缀，则按 `universal` 处理。

## Bridge Feed 字段

`release-feed/stable.json` 在 bridge 期仍使用既有 schema：

- `schemaVersion`
- `channel`
- `release.version`
- `release.releaseNotesURL`
- `release.downloadPageURL`
- `release.deliveryMode`
- `release.minimumAutomaticUpdateVersion`
- `release.artifacts[]`

注意：

- bridge feed 的 URL 和 `sha256` 必须与**重发后的 `v1.1.9` 真实资产**同步。
- 如果 GitHub release 资产被替换，bridge feed 也必须一起更新。

## 发布顺序

这次 `v1.1.9` 重发必须遵守以下顺序：

1. 先构建并确认新的 `1.1.9` 资产
2. 更新 GitHub `v1.1.9` release 资产与 release notes
3. 再更新 `release-feed/stable.json` 的 URL / digest
4. 最后验证：
   - 旧客户端 bridge 生效
   - 新客户端运行时改读 GitHub Releases

## 残余限制

- 已安装**首发 `1.1.9`** 的用户，不会因为“同版本重发”自动看到可升级提示。
- 这些用户必须手工下载并安装重发后的 `1.1.9` build。
- 该限制必须在 release notes、README 和相关更新说明中显式写出。

## 回滚

- 如果某个重发资产需要撤回，不要只删 GitHub release 资产。
- 应同时回滚：
  - GitHub `v1.1.9` release 资产/说明
  - `release-feed/stable.json`
- 目标是让旧客户端 bridge 与新客户端运行时都不再指向已撤回资产。
