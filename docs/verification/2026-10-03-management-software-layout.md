# 管理页软件分段、收起与排序验证

日期：2026-10-03。已安装本地版本：`2.0.0 (52)`。

## 实现范围

- 管理页采用统一的平面软件分段，包含 Codex、Claude Code、OpenCode、Cursor 和 DeepSeek Harness，暂停的软件也保留管理入口。
- Codex 默认收起，点击标题展开或收起，状态保存后在重新创建界面时恢复。
- “排序”模式显示所有软件的上下移动按钮，包括 Codex；顺序持久化，并与看板的额度列表共用。
- Codex 收起时仍显示账号／中转站数量和“连接中转站”。展开后保留四个对齐的路由选择器、账号额度与操作、重置卡以及“第三方中转站”管理。
- 其他软件统一显示额度窗口、余额或简洁的连接状态。标题进入连接管理，菜单提供刷新、历史用量、连接管理、启用／暂停；Cursor 保留 CSV 导入。
- 看板“管理账号与重置卡”导航会切换到管理并展开 Codex，避免进入后看不到账号。

## 检查结果

Debug 编译和 arm64／x86_64 通用 Release 构建成功，`git diff --check` 通过。构建号 `52` 由本次构建参数覆盖，未修改源项目的公开版本号。

八个相关测试类共 54 项：**49 通过、5 跳过、0 失败**。覆盖偏好存储、管理布局、软件额度、Codex 账号额度、连接管理、监控展示以及额度存储。跳过项依赖 SwiftUI 可访问性树，隔离 XCTest 进程未提供该树。

原生窗口交互测试使用自身窗口的鼠标事件和图像文字识别验证：

- 默认收起没有路由控件；实际点击展开后出现四个控件，再次点击后消失。
- 重建偏好存储和界面后，Codex 保持收起。
- 实际进入排序模式，上移／下移 Cursor；保存后的软件顺序、重新读取的偏好和界面中的五个标题顺序一致。
- Codex 收起时“连接中转站”仍显示，展开时路由控件保持完整行宽。

测试使用隔离目录和模拟服务，没有读取真实 OAuth 凭据或发起模型推理。现存 `AutoRoutingCoordinatorTests.swift` 引用已移除的 `invalidCodexAppPath`，本次仅在测试构建参数中排除该文件；未修改该文件，以上结果不代表全量测试通过。

## 本地安装与边界

仅替换 `/Applications/codexbar.app`，保留用户账号和配置数据。安装前后均通过严格签名验证。新安装可执行文件与构建候选的 SHA-256 相同：

`09b8be5bf120cd4112dd4a12531a43f345589c4023771d31376661ec99a2edaa`

已确认运行进程 `69575` 的可执行路径为 `/Applications/codexbar.app/Contents/MacOS/codexbar`，新进程记录了启动、菜单栏宿主启动和单进程服务启动事件。

已安装应用的 CUA 界面读取超时。因此，截图和鼠标交互证据来自隔离原生测试窗口，不作为已安装应用的真实账号连接或完整界面验收证明。

本次生成的 Debug、Release 和临时旧版备份共三个应用副本已清理。清理后 Launch Services 只注册 `/Applications/codexbar.app`，任务临时目录内没有残余 `.app`。Spotlight 查询未返回结果，因此不声称已完成 Spotlight 索引。

保留工作区中无关的 CRAP 文档和脚本修改，未提交或推送。

## 证据位置

- `output/management-layout/2026-10-03/test-summary.json`
- `output/management-layout/2026-10-03/tests.xcresult`
- `output/management-layout/2026-10-03/release-build.log`
- `output/management-layout/2026-10-03/installation-metadata.json`
- `output/management-layout/2026-10-03/screenshots/management-sections-interaction-evidence.txt`
- `output/management-layout/2026-10-03/screenshots/management-sections-reordering-done.png`

该输出目录为本地验证产物，不作为公共发布产物。
