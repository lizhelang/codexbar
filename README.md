# codexbar

让 Codex Desktop 在多账号 / 多 provider 切换时，尽量不丢掉原本的上下文和历史会话。

`codexbar` 是一个面向 macOS 的菜单栏工具。它解决的不是“再建一套 Codex”，而是一个更具体的问题：

> 切账号、切 provider 之后，你想继续共用同一个 `~/.codex` 历史池，而不是把上下文和 session 拆散。

[English](./README.en.md)

它的核心思路很简单：

- 不给每个账号单独建一套 `CODEX_HOME`
- 不拆你的 `~/.codex` 会话池
- 只把当前选中的 provider / account 同步到 `~/.codex/config.toml` 和 `~/.codex/auth.json`
- 切换只影响后续新会话，不会把已有历史 session 从同一个池子里“切没了”

## 界面预览

下面这些图都是**仓库内维护的脱敏演示截图**：界面结构和交互表面与当前产品保持一致，但展示字段已经替换成 demo data，不会暴露真实账号、token，也不依赖你的真实 `~/.codex` / `~/.codexbar` 配置。

### 1. OpenAI 账号视图

可以直接看到当前模式、账号套餐、5 小时 / 7 天两层额度，以及“真正决定恢复可用性”的重置时间。

<p align="center">
  <img src="./docs/assets/readme-openai-accounts-demo.png" alt="codexbar OpenAI accounts demo" width="760" />
</p>

### 2. Provider 管理

同一菜单里可以展开多个 OpenAI 兼容 provider，并在每个 provider 下维护多组 API key 账号。

<p align="center">
  <img src="./docs/assets/readme-providers-demo.png" alt="codexbar providers demo" width="760" />
</p>

### 3. 设置页

设置页把账户模式、手动激活行为、Codex Desktop 路径、排序规则和更新检查整合在一个独立窗口里，不需要再手改配置文件。

<p align="center">
  <img src="./docs/assets/readme-settings-accounts-demo.png" alt="codexbar settings demo" width="1120" />
</p>

## Star 历史

<p align="center">
  <a href="https://star-history.com/#lizhelang/codexbar&Date">
    <picture>
      <source
        media="(prefers-color-scheme: dark)"
        srcset="https://api.star-history.com/svg?repos=lizhelang/codexbar&type=Date&theme=dark"
      />
      <source
        media="(prefers-color-scheme: light)"
        srcset="https://api.star-history.com/svg?repos=lizhelang/codexbar&type=Date"
      />
      <img
        alt="codexbar Star History Chart"
        src="https://api.star-history.com/svg?repos=lizhelang/codexbar&type=Date"
      />
    </picture>
  </a>
</p>

## 它主要解决什么问题

如果你最近会在不同 OpenAI 账号、不同中转站，或者不同 OpenAI 兼容 provider 之间来回切，那么你大概率会遇到同一个痛点：

- 配置切过去了，但上下文像是断了
- 历史 session 还在磁盘里，却因为切账号 / 切 provider 变得不连贯
- 反复手改配置文件很烦，恢复现场也麻烦

`codexbar` 想解决的，就是这件事。

## 不拆 `~/.codex`，保留同一个会话池

很多“多账号切换”方案会直接给每个账号单独建一套 `CODEX_HOME`。这样做隔离很强，但代价也很明显：

- 历史被分散到多份目录
- 切换之后很容易觉得“上下文没了”
- 需要在不同账号环境之间来回找 session

`codexbar` 选的是另一条路：

- 仍然只保留一个 `~/.codex`
- 保留 `~/.codex/sessions` 和 `~/.codex/archived_sessions` 这一套共享历史池
- 当前激活的 provider / account 会同步到 `~/.codex/config.toml` 和 `~/.codex/auth.json`
- 切换只影响之后发起的新请求和新会话

这也是它最核心的价值：切账号 / 切 provider，不等于把 Codex 原本的历史池拆掉。

## 现在支持什么

- 多 OpenAI OAuth 账号管理
- 多 OpenAI 兼容 provider 管理
- 同一 provider 下挂多组 API key
- 菜单栏里快速切换 provider / account
- OpenAI 账号的 **手动切换 / 聚合网关** 双模式
- OpenAI 账号 CSV 导入 / 导出
- OpenAI 账号支持按用量排序 / 按手动顺序排序
- 设置页里配置手动激活策略与 Codex.app 路径
- 本地 usage / 成本统计
- GitHub Releases 运行时版本检测与手动“检查更新”

本地 usage / 成本统计来自对下面目录的扫描：

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

因此你能直接在本地看到 token 用量和成本估算，而不需要手动翻 session 文件。

另外，当前界面还补上了几类更贴近真实日常切换的能力：

- OpenAI 账号支持 **手动切换 / 聚合网关** 两种使用模式
- 支持导入 / 导出 OpenAI 账号 CSV，方便迁移和批量整理
- 支持在设置页里切换 OpenAI 账号排序方式：按当前用量排序，或按手动顺序展示
- 支持设置手动激活行为：只改配置，或直接拉起新的 Codex 实例；已在运行的实例会继续保留
- 当选择“拉起新实例”时，可以在设置页指定 Codex.app 的本地路径；路径失效时会自动回退系统探测

## 版本检测与更新

修复后的客户端运行时会直接扫描 GitHub Releases 列表，选择**第一个可安装的正式稳定版本**；应用启动时会做非阻塞检查，菜单栏里也可以手动触发“检查更新”。

但要特别说明当前边界：

- 当前稳定版本默认仍是 **guided download / install**
- 这表示发现新版本后，codexbar 会在菜单和更新状态里显示可用版本，由你继续打开匹配安装包下载链接
- 运行时会跳过 `draft`、`prerelease`、以及不带 `dmg/zip` 资产的 release
- 当前版本**不会假装**已经支持自动替换旧 app 并自动重启
- `release-feed/stable.json` 只保留这一次 `1.1.8 -> 1.1.9` 的兼容桥接，不再是修复后客户端的运行时真相源
- 如果你已经安装了**首发 1.1.9**，同版本重发不会自动把它识别为可升级；需要手工下载重发 build

更新 bridge / rollout 约定见：

- [docs/update-feed-rollout.md](./docs/update-feed-rollout.md)

## 适合哪些用户

如果你符合下面这些情况，`codexbar` 会比较有用：

- 你会同时使用 OpenAI 官方账号和第三方 OpenAI 兼容 provider
- 你同一个 provider 下会维护多组 API key
- 你不想每次切换都手改 `config.toml`
- 你希望保留同一个 `~/.codex` 的历史池和 resume 体验

## OpenAI 登录方式

当前 OpenAI 登录采用“浏览器授权 + localhost 回调捕获，必要时可手工粘贴回调”的方式。入口在菜单底部工具栏的人像加号按钮：

1. 点击登录按钮
2. 在浏览器里完成授权
3. 当浏览器跳到 `http://localhost:1455/auth/callback?...` 时，codexbar 会自动捕获回调
4. codexbar 直接完成 token 交换并导入账号

如果自动捕获失败，仍然可以把完整回调 URL 或单独的 `code` 手工粘贴回窗口。

## 成本与账单说明

这里展示的是**本地 usage estimate**，不是官方账单页面的精确账单。

需要特别说明：

- token 数量更适合作为稳定指标
- 金额是基于模型价格表的估算
- 对自定义 OpenAI 兼容 provider，显示的金额不一定等于真实供应商扣费

如果某个第三方 provider 的价格策略和 OpenAI 官方定价不同，那 README 和界面里显示的美元金额都只能视为近似估算，不应直接当作实际账单。

## 项目边界

当前版本重点是：

- 多账号管理
- 多 provider 切换
- 共享 `~/.codex` 会话池
- 本地 usage / 成本统计

它不会内置任何私有 provider、私有 API key、私有账号配置。你需要在自己的环境里自行添加这些内容。

## 运行环境

- macOS 13+
- [Codex Desktop / CLI](https://github.com/openai/codex)
- Xcode 15+（如果你要本地编译）

## 本地构建

```sh
git clone https://github.com/lizhelang/codexbar.git
cd codexbar
open codexbar.xcodeproj
```

然后：

1. 在 Xcode 里选择自己的签名团队
2. 构建并运行 `codexbar` target

## 致谢

这个项目参考并改造了下面两个 MIT 许可证项目中的思路与部分实现：

- [xmasdong/codexbar](https://github.com/xmasdong/codexbar)
- [steipete/CodexBar](https://github.com/steipete/CodexBar)

详细说明见：

- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

## License

[MIT](LICENSE)
