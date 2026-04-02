# codexbar

一个面向 Codex Desktop 用户的 macOS 状态栏工具，用来管理多个 OpenAI 账号和多个 OpenAI 兼容 provider，同时尽量保持同一个 `~/.codex` 会话池不被打散。

codexbar 的目标不是替代 Codex Desktop 本身，而是把下面这些操作做得更顺手：

- 切换 OpenAI OAuth 账号
- 切换自定义 OpenAI 兼容 provider
- 给同一个 provider 绑定多个 API key 账号
- 统计本地会话里的 token 与成本历史

## 界面预览

<p align="center">
  <img src="./zh.png" alt="codexbar screenshot" width="720" />
</p>

> 英文说明见文末折叠部分。

## 这是什么

如果你平时会在 Codex Desktop 之外切换不同 provider，或者同一个 provider 下会维护多组账号/API key，这个工具就是把这些状态统一收口到菜单栏里。

它会把当前选中的 provider / account 同步到：

- `~/.codex/config.toml`
- `~/.codex/auth.json`

但不会去拆分你的会话目录，也不会给每个 provider 单独建一套 `CODEX_HOME`。也就是说：

- 你仍然只有一个 `~/.codex`
- Codex Desktop 里的历史 session 仍然保留
- 切换 provider 只影响“后续新会话”

## 核心亮点

- 支持 **多个 OpenAI OAuth 账号**
  用于切换不同 OpenAI/Codex 登录态，并读取对应额度信息。

- 支持 **多个自定义 OpenAI 兼容 provider**
  只要是兼容 OpenAI 接口的 `base_url + api_key` 组合，就可以加入。

- 支持 **同一 provider 下多个账号 / API key**
  适合主账号、备用账号、团队账号并存的情况。

- 保持 **共享的 Codex 会话池**
  不切 `CODEX_HOME`，尽量不破坏 Codex Desktop 原本的历史与 resume 体验。

- 提供 **本地 token / 成本历史**
  从 `~/.codex/sessions` 和 `~/.codex/archived_sessions` 扫描本地会话记录，给出汇总与明细。

## 适合谁

codexbar 适合这些用户：

- 你会同时使用 OpenAI 官方账号和第三方 OpenAI 兼容 provider
- 你不想每次切换都手改 `config.toml`
- 你想在菜单栏里快速切 provider / 账号
- 你想保留同一个 `~/.codex` 的历史池

## 项目特性说明

当前版本重点在于：

- OpenAI OAuth 账号管理
- 自定义 OpenAI 兼容 provider 管理
- 多账号切换
- 本地历史统计

它**不会内置任何私有 provider、私有 API key、私有账号配置**。

仓库里也不会预置作者自己的：

- provider 地址
- key
- 账号
- 计费配置

你需要在自己的环境里自行添加这些内容。

## OpenAI 登录方式

当前 OpenAI 登录采用“浏览器授权 + 手动粘贴回调链接”的方式：

1. 点击 `Login OpenAI`
2. 在浏览器里完成授权
3. 当浏览器地址变成 `http://localhost:1455/auth/callback?...` 时
4. 复制完整地址
5. 回到 codexbar 粘贴
6. 完成 token 交换并导入账号

这样做的目的，是避免单纯依赖本地 localhost 回调监听导致的不稳定行为。

## 成本与账单说明

成本历史来自本地 Codex 会话日志：

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

这里显示的是**本地 usage estimate**，不是官方账单页面的精确账单。

需要特别说明：

- token 数量更适合作为稳定指标
- 金额是基于模型价格表的估算
- 对自定义 OpenAI 兼容 provider，显示的金额不一定等于你的真实供应商扣费

如果某个第三方 provider 的价格策略和 OpenAI 官方定价不同，那“美元金额”只能视为近似估算，不应当直接当作实际账单。

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

<details>
<summary>English</summary>

## Overview

codexbar is a macOS menu bar utility for managing multiple OpenAI accounts and multiple OpenAI-compatible providers while keeping a shared `~/.codex` session pool.

It is intended for users who want faster switching between:

- OpenAI OAuth accounts
- custom OpenAI-compatible providers
- multiple API keys under the same provider

Instead of splitting session storage, codexbar synchronizes the selected provider/account into:

- `~/.codex/config.toml`
- `~/.codex/auth.json`

while keeping Codex Desktop on the same shared session history.

## Highlights

- Multiple OpenAI OAuth accounts
- Custom OpenAI-compatible providers
- Multiple API-key accounts per provider
- Shared `~/.codex` history model
- Local token and cost history from Codex session logs

## Notes

- This repository does not bundle any private provider, API key, or personal account configuration.
- Cost values are estimates derived from local session logs and pricing tables.
- For custom OpenAI-compatible providers, displayed dollar amounts may differ from actual upstream billing.

</details>
