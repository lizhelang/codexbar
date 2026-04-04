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

<p align="center">
  <img src="./zh.png" alt="codexbar screenshot" width="720" />
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
- 本地 usage / 成本统计

本地 usage / 成本统计来自对下面目录的扫描：

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

因此你能直接在本地看到 token 用量和成本估算，而不需要手动翻 session 文件。

## 适合哪些用户

如果你符合下面这些情况，`codexbar` 会比较有用：

- 你会同时使用 OpenAI 官方账号和第三方 OpenAI 兼容 provider
- 你同一个 provider 下会维护多组 API key
- 你不想每次切换都手改 `config.toml`
- 你希望保留同一个 `~/.codex` 的历史池和 resume 体验

## OpenAI 登录方式

当前 OpenAI 登录采用“浏览器授权 + 手动粘贴回调链接”的方式：

1. 点击 `login`
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
