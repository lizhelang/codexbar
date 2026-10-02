# Reserve 模型选择改造验证

## 结果

已将 Reserve 从强制账号路由改为当前 OAuth 账号的模型菜单选项。本地已安装并运行 `1.2.19 (49)`，保留同目录另一个任务的普通聚合预留比例设置。

- 当前请求目标账号有可用 Reserve 额度且未过期、未停用时，在原模型下拉框中显示 `GPT Reserve`（ID `gpt-reserve`）；其他账号有额度不影响该菜单。
- 模型选择按 OAuth 账号保存。Reserve 不改变原普通全局模型偏好，账号切换和重启保留各自选择；额度刷新保留选择，不自动改用普通模型。
- Reserve 使用独立的官方直连 provider 配置，HTTP／WebSocket 按传输设置选择。普通内置 provider 的地址、普通别名以及原网关监听器保持原路由，避免新旧对话恢复时共用不同目标地址。
- 删除旧强制设置、开关、账号标记、网关账号覆盖、Responses／Compact／WebSocket 模型改写及强制重连。旧 JSON 强制键被忽略，后续保存移除，不自动转成 Reserve 模型选择。

## 独立复核

复核发现并关闭：普通 provider 别名及内置 `openai_base_url` 被 Reserve 默认覆盖、固定身份旧网关 listener 被停止、Reserve reasoning 被普通默认模型再次校验三类边界。顶部额度显示已改用实际请求目标账号。

## 工程验证

314 项定向回归最终通过，包含配置迁移、账号模型偏好与凭据轮换、选择失败回滚、请求模型原样转发、新旧连接定义隔离、普通网关生命周期、额度对齐、设置协调和原生界面布局。

首轮 313 项通过，1 项新配置测试仅因直接比较未排序的 JSON 字节失败；改为同一 encoder 的 sortedKeys 比较后重跑该配置组 16 项全部通过。生产代码未因该失败修改。

结果文件：

- `/private/tmp/codexbar-reserve-selection-tests.xcresult`
- `/private/tmp/codexbar-reserve-selection-retry-tests.xcresult`
- `/private/tmp/codexbar-reserve-selection-tests.log`
- `/private/tmp/codexbar-reserve-selection-retry-tests.log`

原生离屏截图检查有额度、未知额度、耗尽额度和选中 Reserve 四种状态，确认账号卡内四个下拉框保持同排、Reserve 额度与推理强度显示正常：`/private/tmp/codexbar-settings-layout/reserve-{available,absent,exhausted,selected}.png`。

## 实际运行与安装

Release 通用构建通过（arm64／x86_64）。应用签名校验通过，`/Applications/codexbar.app` 的版本为 `1.2.19 (49)`，进程持续运行，运行服务启动事件已记录。

安装后通过原生界面控制打开实际应用管理页及模型菜单，确认当前有 Reserve 额度账号的菜单出现 `GPT Reserve`，原普通模型选项和四个设置下拉框保留。验证未选择真实 Reserve，也未发起模型推理或额度对齐，因此不证明服务端模型权限及扣账结果。

清理本次 Debug／Release 构建目录及临时安装备份，Launch Services 核对仅有 `/Applications/codexbar.app`。凭据：

- `/private/tmp/codexbar-reserve-selection-install.json`
- `/private/tmp/codexbar-reserve-selection-installed-check.json`
- `/private/tmp/codexbar-reserve-selection-cleanup.json`
