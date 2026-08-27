# Issue #39：重复会话生命周期记录修复设计

## 背景与根因

`OpenAIRunningThreadAttributionService.load` 把 `SessionLogStore` 返回的生命周期记录按 `session id` 构造成字典。`SessionLogStore` 的缓存键是文件路径，同一个 `session id` 可以因恢复、复制或重命名出现在多个当前会话文件中，因此 `Dictionary(uniqueKeysWithValues:)` 的唯一性前提不成立并会直接触发运行时崩溃。

该字典是一次加载中的局部值，`CoalescedBackgroundRefreshController` 也会合并同一视图的重复刷新请求，所以增加 actor 或串行队列不能修复输入键重复问题。

## 方案比较

1. 为加载过程增加 actor 或锁：不能消除重复键，拒绝。
2. 任意保留第一个或最后一个文件：可以避免崩溃，但文件枚举顺序不应决定线程是否已结束，拒绝。
3. 按生命周期新鲜度确定性合并：保留 `lastActivityAt` 更新的记录；时间相同时优先 `.completed`，采用此方案。

选择第三种方案可以同时覆盖两个方向：较新的 completed 副本会移除已结束线程；较新的 running 副本会保留恢复后的线程。时间完全相同时优先 completed，避免相同快照把已完成线程误报为运行中。

## 改动边界

- 只修改运行线程归因服务的字典构造和对应单元测试。
- 不改变 `SessionLogStore` 的缓存结构、历史成本统计或会话文件扫描规则。
- 不增加新依赖，不引入新的共享状态或并发原语。

## 验收与验证

- 相同 session ID 的多条生命周期记录不再触发崩溃。
- 较新的 completed 记录胜出，并在完成时间不早于运行日志时排除线程。
- 较新的 running 记录胜过旧 completed 记录，恢复的线程仍被计入。
- 相同活动时间时 completed 胜出。
- 运行定向测试、完整 macOS 测试、`xcodebuild analyze`、`git diff --check`，并在合并前执行独立代码审查。
