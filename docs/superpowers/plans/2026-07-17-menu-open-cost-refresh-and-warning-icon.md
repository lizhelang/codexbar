# 菜单打开成本刷新与额度告警图标实施计划

1. 在菜单刷新层引入刷新来源策略，分别定义菜单打开与手动刷新是否更新 session cache。
2. 先增加策略测试，证明菜单打开必须使用 `refreshSessionCache: false`，手动刷新保持 `true`。
3. 修改菜单打开和刷新按钮调用路径，使两者传递不同来源。
4. 更新额度图标测试：低额度及额度耗尽继续生成 usage-bars，更新与封禁仍使用系统符号。
5. 调整图标解析和展示强调，为 warning/critical 提供橙色/红色 tint。
6. 运行定向测试、完整 XCTest、Release/Debug 本地构建与实机 CPU/图标验证。
7. 提交、推送、替换 `/Applications/codexbar.app`，并清理临时 App 与 Launch Services 残留。
