# OpenAI 用户名显示设计

## 目标

为 OpenAI OAuth 账号自动获取并缓存 ChatGPT `username` 与 `display_name`，在菜单、设置和状态文案中优先显示用户名，同时保持 `accountId`、`openAIAccountId`、email 校验、路由和 Codex 配置同步语义不变。

显示顺序固定为：

```text
username → display_name → email → accountId
```

## 已验证的数据源

ChatGPT 第一方网页当前使用以下只读接口：

```http
GET https://chatgpt.com/backend-api/calpico/chatgpt/profile/{chatgpt_user_id}
Authorization: Bearer <access_token>
```

`chatgpt_user_id` 来自 access token 的 `https://api.openai.com/auth` claims。使用当前有效 Codex OAuth token 和 macOS `URLSession` 已验证 HTTP 200，响应包含可选的 `username`、`display_name`、`user_id` 与头像等字段。该地址属于 ChatGPT 内部接口，因此只能作为 best-effort 增强，失败不得影响登录、额度刷新或切号。

标准 OIDC UserInfo 只能可靠取得 `name`、email 等通用资料，不能替代上述 username 接口。

## 方案比较

1. 仅增加本地手动别名：稳定，但没有满足 issue 要求的 OpenAI username 自动读取，拒绝。
2. 仅读取 ID token/OIDC `name`：无需额外请求，但不是 ChatGPT username，拒绝作为完整方案。
3. 独立 profile service + OAuth/额度刷新链路中的非阻塞 enrichment：能满足需求且可隔离内部接口风险，采用。

## 数据与刷新

- `TokenAccount` 和 `CodexBarProviderAccount` 增加可选 `username`、`displayName`、`profileLastCheckedAt`。
- `AccountBuilder` 从 ID token 的 `name` 初始化 `displayName`，username 由 profile service 补齐。
- profile service 使用注入的 `URLSession`，只提交 Bearer token 和必要账号信息，不打印 token 或完整响应。
- profile 最多每小时尝试一次；成功时更新或清空上游字段，失败时保留已有值并记录尝试时间，避免每分钟轮询内部接口。
- OAuth token refresh、auth.json reconcile、provider merge 与 CSV/JSON import 不得清除已缓存资料。

## 展示与分组

- 新增统一 `displayIdentifier`，所有账号标题、错误文案和设置选择器复用。
- 分组同时使用真实 email 与展示标识，防止相同 username 的不同邮箱被误合并；同一 email/username 的多个 workspace 仍保持现有聚合。
- 组标题显示 `displayIdentifier`；点击标题继续复制真实 email，username 不参与复制、匹配或路由。
- email 仍持久化并用于 OAuth 兼容匹配，不因隐藏显示而删除。

## 互通与兼容

- 旧配置缺少新字段时正常解码并回退 email。
- interop JSON 导入导出保留 username/display_name；legacy CSV 格式不增加必填列。
- 账号列表 JSON 保留 `email`，新增可选 username、display_name 与最终 display_label。
- `CodexSyncService` 仍只同步 OAuth token 与稳定 account_id，不写入 username。

## 验证标准

- profile GET 的 URL、Bearer header、响应归一化与失败回退有单元测试。
- username、displayName 和检查时间可持久化并跨刷新保留。
- username 优先，其次 displayName、email、accountId；空白值视为缺失。
- profile 失败不改变 `WhamRefreshOutcome`，usage 402/403 时仍可独立更新 profile。
- 分组不因 username 碰撞合并不同邮箱，点击标题仍复制 email。
- 定向测试、全量 macOS 测试、`xcodebuild analyze`、真实 OAuth 只读 smoke 与独立代码复审全部通过后才合并。
