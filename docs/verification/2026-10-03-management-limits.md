# 管理页完整额度与连接管理

## 改动

- 管理页显示全部已启用数据源的 Token、估算费用、速率与来源状态；今天、本周、本月、总计和 Token／费用切换可用。
- Codex 账号卡显示全部额度窗口、GPT Reserve、重置时间、更新时间及重置卡数量。未知额度保持未知，普通窗口与 Reserve 分开处理；保留账号切换、聚合、路由、刷新、重新登录和删除入口。
- 按软件顺序显示 Claude Code、OpenCode、Cursor、DeepSeek Harness，包含暂停采集的软件。展示额度、余额、连接状态、更新时间，提供刷新、查看用量、管理连接与启用开关。
- 连接面板可保存、选择或恢复默认数据目录，说明各软件已有登录状态及额度来源；Cursor 提供现有 CSV 导入入口。
- 暂停软件停止新的采集请求，仍可单独查看已缓存的历史用量；暂停软件不计入总汇总。暂停不会取消已开始的请求。

## 验证

- Debug 生产应用与 Release 通用应用（arm64／x86_64）构建成功；`git diff --check` 通过。
- 7 个相关测试类共 36 项：32 通过、0 失败、4 跳过。包括额度窗口与重置时间映射、未知值、暂停后的历史用量、目录切换与校验、刷新并发保护、原生布局和管理页交互。
- 隔离 XCTest 进程未公开 SwiftUI AX 控件树，因此 4 项依赖控件树的断言明确跳过，不能据此宣称全部按钮已做交互验收。
- 管理页集成测试在自己的屏幕外原生窗口使用 NSEvent 点击，读取自己生成的位图并核对状态：总计 `34,567` → 今天 `12,345` → 费用 `≥$0.50` → 恢复 Token；“查看用量”切换到看板工具页。
- 已检查管理页、四种软件额度卡、Codex 完整额度卡及连接面板的原生渲染图；合成账号和 mock 额度使用临时数据目录，没有真实 OAuth、额度请求或模型推理。
- 仓库原有 `AutoRoutingCoordinatorTests.swift` 引用了已移除的 `invalidCodexAppPath`，会阻止测试源编译。本次命令仅以 `EXCLUDED_SOURCE_FILE_NAMES=AutoRoutingCoordinatorTests.swift` 排除该文件，没有修改工程或声称全量测试通过。

结果与截图保存在 `output/management-limits/2026-10-03/`：

- `test-summary.json`、`final-tests.log`、`final-tests.xcresult`
- `release-build.log`、`installation-metadata.json`
- `screenshots/management-quota-allTime.png`、`management-quota-bottom.png`
- `screenshots/management-quota-interaction-evidence.txt`
- `screenshots/connection-*.png`

## 本机状态与清理

- 用户明确要求重装后，已将新版安装到 `/Applications/codexbar.app` 并重启。当前为 `2.0.0 (51)`；仅本次本机构建覆盖 build number 为 51，工程中的发布版本设置未改。
- 新旧应用均使用 ad-hoc 签名，安装前后严格签名校验通过。新应用可执行文件 SHA-256 与候选产物一致，且与原 `(50)` 版本不同。
- 新进程运行路径为 `/Applications/codexbar.app/Contents/MacOS/codexbar`；启动记录确认菜单栏及运行服务已启动。原生界面自动读取两次超时，未把离屏测试截图描述为安装后的真实截图。
- 已注销并删除本次 Debug／Release 临时 DerivedData 与安装回滚备份，保存的验证产物不含 `.app`。
- Launch Services 最终只登记 `/Applications/codexbar.app`；对应 bundle identifier 的 Spotlight 查询无结果，未发现重复入口。
- 保留原有未跟踪的 CRAP 文档、脚本与测试；没有修改真实账号文件或用户数据。
