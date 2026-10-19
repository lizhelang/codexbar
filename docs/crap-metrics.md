# 可重复的 Swift 方法 CRAP 评估

入口是 `scripts/crap_metrics.py`，使用已有 Python 3.9+ 标准库、SwiftLint 和 Xcode 的 `xccov`。它不运行应用、访问服务端或修改用户配置；只读取项目源码、Git 文件历史及明确指定的覆盖率/测试摘要，写入指定报告。真实用户的 `.codex` 和 `.codexbar` 目录禁止作为报告输入或输出。

## 计算口径

```ini
CRAP = complexity² × (1 - coverage)³ + complexity
complexity = SwiftLint cyclomatic_complexity 的分支增量 + 1 条基础路径
coverage = xccov 指定 target 的方法行覆盖率，取值 0..1
```

SwiftLint 0.65.1 的直线函数增量是 0，加入基础路径后复杂度为 1。该口径计算 if、guard、循环、catch、switch case，扣除 fallthrough；不单独计算 `&&`、`||`、三元条件。它包含方法内部 closure 的分支，不包含嵌套函数的分支。它是本报告明确采用的工具等价复杂度，不能与其他工具的完整布尔条件口径直接比较。对应实现见 [SwiftLint rule](https://github.com/realm/SwiftLint/blob/0.65.1/Source/SwiftLintBuiltInRules/Rules/Metrics/CyclomaticComplexityRule.swift)。

规则测量具备函数体的函数和初始化方法，不测量 computed property、accessor、subscript、deinit 和 SwiftUI `body`。因此 UI 的大部分声明式布局不在本指标的完整观察范围内。Python 声明解析仅辅助名称/位置关联，复杂度不由正则表达式估算；关联失败会停止评估。覆盖率关联歧义或缺失则明确记录 unknown。

覆盖率优先按文件与方法声明位置关联 `xccov.functions`，支持多行签名的函数体起始位置；拒绝把 default argument、implicit function 或 closure 的计数冒充父方法。Swift 的具名函数和独立 closure 仍有统计边界差异，父方法高行覆盖不证明所有 closure 被执行，更不证明所有条件、失败路径或断言受到验证。

没有方法数据时 `coverage` 和 `crap` 都是 JSON `null`，人工摘要显示 `unknown`。缺失不等于 0。只有显式指定 `--include-approximation` 时，才允许缺少方法数据的文件级行覆盖近似；报告会标记 `approximation: true`、`granularity: file_line`，并将其与方法级分数分组排序。

初始阈值为 `<15`、`15–30`、`>=30`、`>=50`，其中 30 和 50 的边界分别进入复查、高优先级候选。可通过 `--thresholds` 调整；这些不是项目发布或账号安全门槛。即使覆盖率为 100%，CRAP 仍等于复杂度本身。

## 直接使用已有覆盖率

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v

python3 scripts/crap_metrics.py \
  --project . \
  --source-dir codexBar \
  --exclude experiments \
  --coverage-report output/crap/2026-10-03/coverage.json \
  --coverage-target codexbarTests.xctest \
  --test-summary output/crap/2026-10-03/test-summary.json \
  --min-complexity 1 --top 10 \
  --include-unknown --no-include-approximation \
  --thresholds 15,30,50 \
  --output output/crap/2026-10-03/metrics.json \
  --summary-output output/crap/2026-10-03/summary.md
```

`--project` 可指定仓库或目录；`--source-dir`、`--exclude` 可重复。`--coverage-report` 接受 `xccov` JSON、`.xccovreport` 或 `.xcresult`。JSON 保存全部方法和未知项以便复评；`--top`、`--min-complexity`、`--no-include-unknown` 控制人工摘要。`--include-approximation` 同时控制文件级近似的启用和展示。没有覆盖率时省略该参数即可得到全为 unknown 的静态候选，不生成伪分数。

本仓库把生产源码编入独立 XCTest target。评估默认选择 `codexbarTests.xctest`，排除另一个 App target 和测试文件的指标，避免将未运行/重复编译的目标混合、择优或平均。通用项目可显式更换 `--coverage-target`。给定报告需要与当前源码对应；报告记录 Git HEAD、当前源码 SHA-256 和工具版本，但 `xccov` 本身不提供源码散列，不能自动证明旧覆盖率仍适用于后来改动过的源码。

关联测试数量是按源码文件名/类型名在测试文件中的引用推断的声明数量，并非方法级测试数量、覆盖该方法的执行次数或精确调用关系；真正的方法级测试数量保留为 unknown。错误/回归命名测试仅说明存在相应测试名，不能证明覆盖该方法。历史缺陷保留 unknown。近期频繁修改仅按文件在指定 Git 时间窗内的提交数判断，`--churn-days` 和 `--frequent-change-count` 可调整，方法级改动频度保留 unknown。敏感边界和环境依赖是文件级推断，需人工确认。

默认排除 build、DerivedData、dist、release、.build、ThirdParty、Pods、Carthage、vendor、依赖缓存、生成代码、测试/fixture、实验和探针目录。探针/实验如果放在普通源码目录，应额外传入 `--exclude`。发布脚本等非 Swift 文件不纳入这一方法口径，单独记录流程风险。

## 从安全 XCTest 收集覆盖率

当前 shell 全局设置 `CC/CXX` 为 Homebrew LLVM 会导致 Xcode SDK 模块不兼容。构建使用单次环境清理和显式 Apple 编译器，不修改 `.zshrc`、`.bash_profile` 或项目发布配置。Apple 文档说明命令行传入的构建设置具有最高优先级：[配置构建设置](https://developer.apple.com/documentation/xcode/configuring-the-build-settings-of-a-target/)。

```bash
crap_run_dir=$(mktemp -d /private/tmp/codexbar-crap.XXXXXX)

env -u CC -u CXX -u CPP \
  CODEXBAR_HOME="$crap_run_dir/isolated-home" \
  TEST_RUNNER_CODEXBAR_HOME="$crap_run_dir/isolated-home" \
  xcodebuild test -project codexbar.xcodeproj -scheme codexbar \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO -enableCodeCoverage YES \
  -derivedDataPath "$crap_run_dir/DerivedData" \
  -resultBundlePath "$crap_run_dir/tests.xcresult" \
  CC="$(xcrun --find clang)" CXX="$(xcrun --find clang++)" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO -jobs 4

xcrun xccov view --report --json "$crap_run_dir/tests.xcresult"
xcrun xcresulttool get test-results summary --path "$crap_run_dir/tests.xcresult"
```

当前基线有已知过时测试，见日期报告；全量命令会被它阻塞。仅为测量其余安全测试，本次额外传入 `EXCLUDED_SOURCE_FILE_NAMES=AutoRoutingCoordinatorTests.swift`，不把这一排除写入项目配置，也不将部分测试视作全量通过。XCTest 用自己的临时 home/mock/fixture，不应开启需要真实源的 opt-in 测试。

收集完毕后保留覆盖率 JSON、测试摘要及必要 `.xcresult`，移除本次临时 DerivedData 中的 App；如果注册过临时 App，注销其精确路径，并核对 Launch Services/Spotlight 中最终只保留目标安装副本。不要清空共享 DerivedData 或删除用户归档。

## 可信边界

- 方法行覆盖和 CRAP 是本次指定测试样本的代码指标，不是整体质量分数。
- 本地/mock OAuth、callback 输入和临时认证 fixture 不能证明真实浏览器、授权服务端、真实账号、额度或计费资格。
- 离屏菜单栏/设置 UI 验证不能证明系统通知、权限、Launch Services 或所有 macOS 版本行为。
- 配对密钥、OAuth 凭据、认证状态、配置迁移和回滚需要独立工程审查；分数不提供安全验收。
- 本入口不签名、公证、安装、替换、上传或发布应用；其通过不证明可以生产发布。
