import Foundation

/// Bilingual string helper — detects system language at runtime, with user override.
enum L {
    /// nil = follow system, true = force Chinese, false = force English
    nonisolated static var languageOverride: Bool? {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: "languageOverride") != nil else { return nil }
            return d.bool(forKey: "languageOverride")
        }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: "languageOverride")
            } else {
                UserDefaults.standard.removeObject(forKey: "languageOverride")
            }
        }
    }

    nonisolated static var zh: Bool {
        if let override = languageOverride { return override }
        let lang = Locale.current.language.languageCode?.identifier ?? ""
        return lang.hasPrefix("zh")
    }

    // MARK: - Status Bar
    static var weeklyLimit: String { zh ? "周限额" : "Weekly Limit" }
    static var hourLimit: String   { zh ? "5h限额" : "5h Limit" }

    // MARK: - MenuBarView
    static var noAccounts: String      { zh ? "还没有账号"          : "No Accounts" }
    static var addAccountHint: String  { zh ? "点击下方 + 添加账号"   : "Tap + below to add an account" }
    static var refreshUsage: String    { zh ? "刷新用量"            : "Refresh Usage" }
    static var checkForUpdates: String { zh ? "检查更新"            : "Check for Updates" }
    static func menuUpdateAvailableTitle(_ version: String) -> String {
        zh ? "发现新版本 v\(version)" : "Version \(version) Is Available"
    }
    static func menuUpdateAvailableSubtitle(_ currentVersion: String, _ latestVersion: String) -> String {
        zh ? "当前为 \(currentVersion)，现在可以继续下载或安装 \(latestVersion)。" : "You're on \(currentVersion). Download or install \(latestVersion) now."
    }
    static var menuUpdateAction: String { zh ? "更新" : "Update" }
    static var addAccount: String      { zh ? "添加账号"            : "Add Account" }
    static var openAICSVToolbar: String { zh ? "导入或导出 OpenAI CSV" : "Import or Export OpenAI CSV" }
    static func codexLaunchSwitchedInstanceStarted(_ account: String) -> String {
        zh ? "已切换到「\(account)」，并为该账号新开一个 Codex 实例。" : "Switched to \"\(account)\" and launched a new Codex instance for it."
    }
    static var codexLaunchProbeAppNotFound: String {
        zh ? "未找到 Codex.app" : "Codex.app was not found"
    }
    static var codexLaunchProbeExecutableMissing: String {
        zh ? "未找到 bundled codex 可执行文件" : "The bundled codex executable was not found"
    }
    static var codexLaunchProbeTimedOut: String {
        zh ? "启动 Codex.app 超时" : "Launching Codex.app timed out"
    }
    static func codexLaunchProbeFailed(_ message: String) -> String {
        zh ? "受管启动探针失败：\(message)" : "Managed launch probe failed: \(message)"
    }
    static var exportOpenAICSVAction: String { zh ? "导出 OpenAI CSV…" : "Export OpenAI CSV…" }
    static var importOpenAICSVAction: String { zh ? "导入 OpenAI CSV…" : "Import OpenAI CSV…" }
    static var settings: String { zh ? "设置" : "Settings" }
    static func updateInstallActionHelp(_ version: String) -> String {
        zh ? "下载或安装 \(version)" : "Download or Install \(version)"
    }
    static var updateInstallLocationOther: String {
        zh ? "非标准路径" : "Non-standard Location"
    }
    static var updateArchitectureUniversal: String {
        zh ? "通用构建" : "Universal Build"
    }
    static var updateSignatureUnknown: String {
        zh ? "未能读取应用签名信息" : "Unable to read the app signature"
    }
    static var updateBlockerGuidedDownloadOnlyRelease: String {
        zh ? "当前可用版本仍要求走引导下载/安装，不宣称自动替换闭环。" : "The current release still requires guided download/install instead of automatic replacement."
    }
    static func updateBlockerBootstrapRequired(_ currentVersion: String, _ minimumAutomaticVersion: String) -> String {
        zh
            ? "Bootstrap / Rollout Gate 未满足：\(currentVersion) 仍需先人工安装到 \(minimumAutomaticVersion) 或更高版本，自动更新闭环才从后续版本开始。"
            : "Bootstrap / rollout gate not satisfied: \(currentVersion) must first be manually upgraded to \(minimumAutomaticVersion) or later before automatic updates can be closed-loop."
    }
    static var updateBlockerAutomaticUpdaterUnavailable: String {
        zh ? "当前仓库尚未接入可用的成熟自动更新引擎。" : "A mature automatic update engine is not wired into this repository yet."
    }
    static func updateBlockerMissingTrustedSignature(_ summary: String) -> String {
        zh
            ? "当前安装缺少可用于成熟 updater 的可信签名：\(summary)"
            : "This installation lacks a trusted signature suitable for a mature updater: \(summary)"
    }
    static func updateBlockerGatekeeperAssessment(_ summary: String) -> String {
        zh
            ? "当前安装未通过 Gatekeeper / 分发前置条件：\(summary)"
            : "This installation does not satisfy the Gatekeeper / distribution prerequisites: \(summary)"
    }
    static func updateBlockerUnsupportedInstallLocation(_ pathDescription: String) -> String {
        zh
            ? "当前安装路径为 \(pathDescription)，尚未纳入可自动替换的受支持范围。"
            : "The current install location is \(pathDescription), which is not yet in the supported auto-replace matrix."
    }
    static var updateErrorMissingReleasesURL: String {
        zh ? "未配置 GitHub Releases API 地址。" : "The GitHub Releases API URL is not configured."
    }
    static func updateErrorInvalidCurrentVersion(_ version: String) -> String {
        zh ? "当前版本号无效：\(version)" : "Invalid current version: \(version)"
    }
    static func updateErrorInvalidReleaseVersion(_ version: String) -> String {
        zh ? "最新稳定版本号无效：\(version)" : "Invalid latest stable version: \(version)"
    }
    static var updateErrorInvalidResponse: String {
        zh ? "GitHub Releases 响应无效。" : "The GitHub Releases response is invalid."
    }
    static func updateErrorUnexpectedStatusCode(_ statusCode: Int) -> String {
        zh ? "GitHub Releases API 返回异常状态码：\(statusCode)" : "The GitHub Releases API returned status code \(statusCode)."
    }
    static var updateErrorNoInstallableStableRelease: String {
        zh ? "GitHub Releases 中未找到可安装的正式稳定版本。" : "No installable stable release was found on GitHub Releases."
    }
    static func updateErrorNoCompatibleArtifact(_ architecture: String) -> String {
        zh ? "最新稳定版本中缺少适用于 \(architecture) 的安装包。" : "The latest stable release does not contain a compatible installer for \(architecture)."
    }
    static func updateErrorFailedToOpenDownloadURL(_ url: String) -> String {
        zh ? "无法打开下载链接：\(url)" : "Failed to open the download URL: \(url)"
    }
    static var updateErrorAutomaticUpdateUnavailable: String {
        zh ? "当前构建尚未接入可执行的自动更新引擎。" : "An executable automatic update engine is not available in this build."
    }
    static var settingsWindowTitle: String { self.settings }
    static var settingsWindowHint: String {
        zh
            ? "左侧切换账户、用量和更新设置。窗口内的修改会先保存在草稿里，点击保存后再统一生效。"
            : "Use the sidebar to switch between account, usage, and update settings. Changes stay in a window draft until you save."
    }
    static var settingsAccountsPageTitle: String { zh ? "账户设置" : "Account Settings" }
    static var settingsUsagePageTitle: String { zh ? "用量设置" : "Usage Settings" }
    static var settingsCodexAppPathPageTitle: String { zh ? "Codex App 路径设置" : "Codex App Path" }
    static var settingsUpdatesPageTitle: String { zh ? "更新" : "Updates" }
    static var settingsUpdatesPageHint: String {
        zh
            ? "从这里检查 GitHub Releases 上首个可安装的正式稳定版本，并继续下载或安装当前可用更新。"
            : "Check the first installable stable release on GitHub Releases here, then continue to download or install the current update."
    }
    static var settingsUpdatesCurrentVersionTitle: String { zh ? "当前版本" : "Current Version" }
    static var settingsUpdatesLatestVersionTitle: String { zh ? "GitHub 最新稳定版本" : "Latest Stable Version on GitHub" }
    static var settingsUpdatesStatusTitle: String { zh ? "更新状态" : "Update Status" }
    static var settingsUpdatesUnknownVersion: String { zh ? "尚未检查" : "Not Checked Yet" }
    static var settingsUpdatesCheckAction: String { zh ? "检查 GitHub 上的最新稳定版本" : "Check the Latest Stable Version on GitHub" }
    static var settingsUpdatesInstallAction: String { zh ? "继续下载或安装更新" : "Continue Download or Install" }
    static var settingsUpdatesChecking: String { zh ? "正在检查 GitHub 上的最新稳定版本…" : "Checking the latest stable version on GitHub..." }
    static var settingsUpdatesIdle: String { zh ? "尚未发起更新检查。" : "No update check has been started yet." }
    static var settingsUpdatesSourceNote: String {
        zh
            ? "运行时会扫描 GitHub Releases 列表，只认非 draft、非 prerelease、且带 dmg/zip 安装包的正式 release。"
            : "Runtime checks scan the GitHub Releases list and only accept non-draft, non-prerelease releases that ship installable dmg/zip assets."
    }
    static var settingsUpdatesReissueLimitNote: String {
        zh
            ? "如果你已安装首发 1.1.9，同版本重发不会自动显示为可升级；需要手工下载重发 build。"
            : "If you already installed the first 1.1.9 build, a same-version reissue will not show up as an upgrade automatically; you must download the reissued build manually."
    }
    static func settingsUpdatesUpToDate(_ version: String) -> String {
        zh ? "当前版本 \(version) 已与 GitHub 上的最新稳定版本一致。" : "The current version \(version) already matches the latest stable version on GitHub."
    }
    static func settingsUpdatesAvailable(_ currentVersion: String, _ latestVersion: String) -> String {
        zh ? "当前版本 \(currentVersion)，GitHub 上可用最新稳定版本 \(latestVersion)。" : "Current version \(currentVersion); the latest stable version on GitHub is \(latestVersion)."
    }
    static func settingsUpdatesExecuting(_ version: String) -> String {
        zh ? "正在处理 \(version) 的更新动作。" : "Processing the update action for \(version)."
    }
    static func settingsUpdatesFailed(_ message: String) -> String {
        zh ? "更新失败：\(message)" : "Update failed: \(message)"
    }
    static var usageDisplayModeTitle: String { zh ? "用量显示方式" : "Usage Display" }
    static var remainingUsageDisplay: String { zh ? "剩余用量" : "Remaining Quota" }
    static var usedQuotaDisplay: String { zh ? "已用额度" : "Used Quota" }
    static var remainingShort: String { zh ? "剩余" : "Remaining" }
    static var usedShort: String { zh ? "已用" : "Used" }
    static var quotaSortSettingsTitle: String { zh ? "用量排序参数" : "Quota Sort Parameters" }
    static var quotaSortSettingsHint: String {
        zh
            ? "排序仍按用量规则计算，正在使用和运行中的账号优先。这里仅调整套餐权重换算：默认 free=1、plus=10、pro=plus×10（可调 5 到 30）、team=plus×1.5。"
            : "Sorting still follows quota usage rules, with active and running accounts first. These controls only adjust plan weighting: by default free=1, plus=10, pro=plus×10 (adjustable from 5 to 30), and team=plus×1.5."
    }
    static var quotaSortPlusWeightTitle: String { zh ? "Plus 相对 Free 权重" : "Plus Weight vs Free" }
    static var quotaSortProRatioTitle: String { zh ? "Pro 相对 Plus 倍数" : "Pro Ratio vs Plus" }
    static var quotaSortTeamRatioTitle: String { zh ? "Team 相对 Plus 倍数" : "Team Ratio vs Plus" }
    static var accountUsageModeTitle: String { zh ? "账号使用模式" : "Account Usage Mode" }
    static var accountUsageModeHint: String {
        zh
            ? "切换模式沿用当前逐账号生效方式；聚合模式会把 Codex 指向本地 gateway，并在后台按会话把请求路由到合适账号。"
            : "Switch mode keeps the current per-account activation flow. Aggregate mode points Codex to a local gateway that routes sessions across your OpenAI accounts."
    }
    static var accountUsageModeAggregate: String { zh ? "聚合网关" : "Aggregate Gateway" }
    static var accountUsageModeAggregateShort: String { zh ? "聚合" : "Aggregate" }
    static var accountUsageModeAggregateHint: String {
        zh
            ? "OpenAI OAuth 账号会被当成一个本地账号池。Codex 连接本地 gateway，gateway 按会话粘性与 failover 规则挑选账号，不再依赖重启 Codex 才切号。"
            : "Treat OpenAI OAuth accounts as one local pool. Codex talks to a local gateway, which applies session stickiness and failover instead of relying on process restarts to switch accounts."
    }
    static var accountUsageModeSwitch: String { zh ? "手动切换" : "Manual Switch" }
    static var accountUsageModeSwitchShort: String { zh ? "切换" : "Switch" }
    static var accountUsageModeSwitchHint: String {
        zh
            ? "保持当前行为：手动点账号后才切换，Codex 直接使用那个账号写入的 auth/config。"
            : "Keep the current behavior: switching only happens when you explicitly choose an account, and Codex uses that account's synced auth/config directly."
    }
    static func quotaSortPlusWeightValue(_ value: Double) -> String {
        let formatted = String(format: "%.1f", value)
        return zh ? "plus=\(formatted)" : "plus=\(formatted)"
    }
    static func quotaSortProRatioValue(_ value: Double, absoluteProWeight: Double) -> String {
        let ratio = String(format: "%.1f", value)
        let proWeight = String(format: "%.1f", absoluteProWeight)
        return zh ? "pro=plus×\(ratio) (= \(proWeight))" : "pro=plus×\(ratio) (= \(proWeight))"
    }
    static func quotaSortTeamRatioValue(_ value: Double, absoluteTeamWeight: Double) -> String {
        let ratio = String(format: "%.1f", value)
        let teamWeight = String(format: "%.1f", absoluteTeamWeight)
        return zh ? "team=plus×\(ratio) (= \(teamWeight))" : "team=plus×\(ratio) (= \(teamWeight))"
    }
    static var accountOrderTitle: String { zh ? "OpenAI 账号顺序" : "OpenAI Account Order" }
    static var accountOrderingModeTitle: String { zh ? "账号排序方式" : "Account Ordering" }
    static var accountOrderingModeHint: String {
        zh
            ? "可在“按用量排序”和“按手动顺序”之间切换。只有切到手动顺序时，下面的手动排序才会影响主菜单展示。"
            : "Switch between quota-based sorting and manual order. The manual list below only affects the main menu when manual order is selected."
    }
    static var accountOrderingModeQuotaSort: String { zh ? "按用量排序" : "Sort by Quota" }
    static var accountOrderingModeQuotaSortHint: String {
        zh ? "直接按当前用量权重排序，剩余可用更多的账号优先。" : "Use the current quota-weighted ranking directly, with accounts that have more usable quota first."
    }
    static var accountOrderingModeManual: String { zh ? "按手动顺序" : "Manual Order" }
    static var accountOrderingModeManualHint: String {
        zh ? "按你保存的手动顺序展示；active / running 账号仍会临时浮顶。" : "Use your saved manual order for display; active and running accounts still float to the top temporarily."
    }
    static var accountOrderHint: String {
        zh
            ? "这里定义手动顺序。只有在上方选了“按手动顺序”后它才生效；active / running 账号仍会临时浮顶。"
            : "This defines the manual order. It only takes effect when \"Manual Order\" is selected above, and active/running accounts still float to the top."
    }
    static var accountOrderInactiveHint: String {
        zh ? "当前按用量排序；你仍可预先调整手动顺序，等切到“按手动顺序”后再生效。" : "Quota sorting is currently active. You can still prepare the manual order below, and it will apply once you switch to Manual Order."
    }
    static var noOpenAIAccountsForOrdering: String { zh ? "当前没有可排序的 OpenAI 账号。" : "There are no OpenAI accounts to reorder." }
    static var moveUp: String { zh ? "上移" : "Move Up" }
    static var moveDown: String { zh ? "下移" : "Move Down" }
    static var manualActivationBehaviorTitle: String { zh ? "手动点击 OpenAI 账号时" : "When Manually Clicking an OpenAI Account" }
    static var manualActivationBehaviorHint: String {
        zh
            ? "只影响 OpenAI OAuth 账号的手动点击，不会扩展到 custom provider。"
            : "This only affects manual clicks on OpenAI OAuth accounts and does not extend to custom providers."
    }
    static var manualActivationUpdateConfigOnly: String { zh ? "只改默认目标" : "Default Target Only" }
    static var manualActivationUpdateConfigOnlyHint: String {
        zh ? "只更新 future default target；当前运行中的 thread 不保证切换。" : "Only updates the future default target; running threads are not guaranteed to switch."
    }
    static var manualActivationLaunchNewInstance: String { zh ? "新开实例" : "Launch New Instance" }
    static var manualActivationLaunchNewInstanceHint: String {
        zh
            ? "更新默认目标后立刻拉起新的 Codex App 实例；已在运行的 Codex 实例会继续保留。"
            : "Update the default target and immediately launch a new Codex App instance. Already-running Codex instances stay open."
    }
    static var manualActivationUpdateConfigOnlyOneTime: String { zh ? "只改默认目标（本次）" : "Default Target Only (This Time)" }
    static var manualActivationLaunchNewInstanceOneTime: String { zh ? "新开实例（本次）" : "Launch New Instance (This Time)" }
    static var manualActivationSetDefaultTargetAction: String { zh ? "设为默认" : "Set Default" }
    static var manualActivationLaunchInstanceAction: String { zh ? "新开实例" : "Launch Instance" }
    static var manualSwitchDefaultTargetUpdatedTitle: String {
        zh ? "默认目标已更新" : "Default target updated"
    }
    static func manualSwitchDefaultTargetUpdatedDetail(_ target: String?) -> String {
        if let target, target.isEmpty == false {
            return zh
                ? "后续新请求默认走 \(target)；当前运行中的 thread 不保证切换。"
                : "New requests now default to \(target); running threads are not guaranteed to switch."
        }
        return zh
            ? "后续新请求会使用新的默认目标；当前运行中的 thread 不保证切换。"
            : "New requests will use the new default target; running threads are not guaranteed to switch."
    }
    static var manualSwitchLaunchedInstanceTitle: String {
        zh ? "默认目标已更新并已新开实例" : "Default target updated and new instance launched"
    }
    static func manualSwitchLaunchedInstanceDetail(_ target: String?) -> String {
        if let target, target.isEmpty == false {
            return zh
                ? "新的 Codex 实例会使用 \(target)；已在运行的实例会继续保留，现有 thread 也不会被接管。"
                : "The new Codex instance will use \(target); existing instances stay open, and running threads keep their current target."
        }
        return zh
            ? "新的 Codex 实例会使用新的默认目标；已在运行的实例会继续保留，现有 thread 也不会被接管。"
            : "The new Codex instance will use the new default target; existing instances stay open, and running threads keep their current target."
    }
    static var manualSwitchImmediateEffectHint: String {
        zh ? "如要立刻生效，请新开实例。" : "Launch a new instance if you need it to take effect immediately."
    }
    static var aggregateRuntimeActiveTitle: String {
        zh ? "聚合运行态仍在影响后续路由" : "Aggregate runtime is still affecting future routing"
    }
    static func aggregateRuntimeActiveDetail(_ routedAccount: String?) -> String {
        if let routedAccount, routedAccount.isEmpty == false {
            return zh
                ? "最近路由摘要仍停留在 \(routedAccount)。同一 thread 可能继续沿用旧 sticky；这只是摘要，不代表全部 live thread。"
                : "The latest route summary still points at \(routedAccount). The same thread may keep following an older sticky binding; this is only a summary, not the truth for every live thread."
        }
        return zh
            ? "聚合 gateway 仍按会话路由 OpenAI 账号。最近路由只作摘要，不代表全部 live thread。"
            : "The aggregate gateway is still routing OpenAI accounts per session. The latest route is only a summary, not the truth for every live thread."
    }
    static var aggregateRuntimeSwitchBackTitle: String {
        zh ? "新流量已回手动切换，旧聚合线程仍在续跑" : "New traffic is back on switch mode while old aggregate threads keep running"
    }
    static func aggregateRuntimeSwitchBackDetail(
        targetAccount: String?,
        routedAccount: String?
    ) -> String {
        if let targetAccount, targetAccount.isEmpty == false,
           let routedAccount, routedAccount.isEmpty == false {
            return zh
                ? "默认目标是 \(targetAccount)，但最近路由摘要仍停留在 \(routedAccount)。这通常是旧 aggregate lease 或 sticky 尚未自然收敛，不代表切号失败。"
                : "The default target is \(targetAccount), but the latest route summary still points at \(routedAccount). That usually means an older aggregate lease or sticky binding has not naturally drained yet, not that switching failed."
        }
        if let targetAccount, targetAccount.isEmpty == false {
            return zh
                ? "默认目标已回到 \(targetAccount)，但旧 aggregate lease 或 sticky 仍可能影响未结束的线程。这不代表切号失败。"
                : "The default target is back on \(targetAccount), but an older aggregate lease or sticky binding may still affect threads that have not finished. That does not mean switching failed."
        }
        return zh
            ? "新流量已回手动切换，但旧 aggregate lease 或 sticky 仍可能影响尚未结束的线程。这不代表切号失败。"
            : "New traffic is back on switch mode, but an older aggregate lease or sticky binding may still affect threads that have not finished. That does not mean switching failed."
    }
    static var aggregateRuntimeClearStaleStickyAction: String {
        zh ? "清理过期 sticky" : "Clear Stale Sticky"
    }
    static var aggregateRuntimeClearStaleStickyHint: String {
        zh
            ? "清理后只影响 future routing / new thread，不接管正在运行的 thread。"
            : "Clearing it only affects future routing / new threads and does not take over running threads."
    }
    static var save: String { zh ? "保存" : "Save" }
    static var codexAppPathTitle: String { zh ? "文件路径" : "Path" }
    static var codexAppPathHint: String {
        zh
            ? "手动路径优先；路径失效时会自动回退系统探测。有效路径必须是绝对路径、指向 Codex.app，并包含 Contents/Resources/codex。"
            : "A manual path takes priority, but invalid paths fall back to automatic detection. Valid paths must be absolute, point to Codex.app, and include Contents/Resources/codex."
    }
    static var codexAppPathChooseAction: String { zh ? "选择" : "Choose" }
    static var codexAppPathResetAction: String { zh ? "恢复自动探测" : "Use Auto Detection" }
    static var codexAppPathPanelTitle: String { zh ? "选择 Codex.app" : "Choose Codex.app" }
    static var codexAppPathPanelMessage: String {
        zh ? "请选择一个有效的 Codex.app。" : "Choose a valid Codex.app."
    }
    static var codexAppPathEmptyValue: String { zh ? "当前未设置手动路径" : "No manual path selected" }
    static var codexAppPathUsingManualStatus: String { zh ? "使用手动路径" : "Using the manual path" }
    static var codexAppPathInvalidFallbackStatus: String { zh ? "手动路径无效，已回退自动探测" : "Manual path is invalid; falling back to automatic detection" }
    static var codexAppPathAutomaticStatus: String { zh ? "当前使用自动探测" : "Currently using automatic detection" }
    static var codexAppPathInvalidSelection: String {
        zh
            ? "所选路径不是有效的 Codex.app。请确认它是绝对路径、名为 Codex.app，并包含 Contents/Resources/codex。"
            : "The selected path is not a valid Codex.app. Make sure it is an absolute path named Codex.app and includes Contents/Resources/codex."
    }
    static var openAICSVExportPrompt: String { zh ? "导出" : "Export" }
    static var openAICSVImportPrompt: String { zh ? "导入" : "Import" }
    static var noOpenAIAccountsToExport: String {
        zh ? "没有可导出的 OpenAI 账号" : "No OpenAI accounts available to export"
    }
    static func openAICSVExportSucceeded(_ count: Int) -> String {
        zh ? "已导出 \(count) 个 OpenAI 账号到 CSV。" : "Exported \(count) OpenAI account\(count == 1 ? "" : "s") to CSV."
    }
    static func openAICSVImportSucceeded(
        added: Int,
        updated: Int,
        activeChanged: Bool,
        providerChanged: Bool,
        preservedCompatibleProvider: Bool
    ) -> String {
        let prefix = zh
            ? "已导入 OpenAI CSV：新增 \(added) 个，覆盖 \(updated) 个。"
            : "Imported OpenAI CSV: \(added) added, \(updated) updated."
        let suffix: String
        if preservedCompatibleProvider {
            suffix = zh ? " 当前使用 provider 保持不变。" : " The current provider was left unchanged."
        } else if providerChanged {
            suffix = zh ? " 当前 provider 已切换到 OpenAI。" : " The current provider was switched to OpenAI."
        } else if activeChanged {
            suffix = zh ? " 当前 OpenAI 账号已更新。" : " The current OpenAI account was updated."
        } else {
            suffix = zh ? " 当前 active 选择未变化。" : " The current active selection was unchanged."
        }
        return prefix + suffix
    }
    static var openAICSVEmptyFile: String { zh ? "CSV 为空，或只有表头。" : "The CSV is empty or only contains a header." }
    static var openAICSVMissingColumns: String { zh ? "CSV 缺少必需列。" : "The CSV is missing required columns." }
    static var openAICSVUnsupportedVersion: String { zh ? "不支持的 CSV 版本。" : "Unsupported CSV format version." }
    static func openAICSVInvalidRow(_ row: Int) -> String {
        zh ? "CSV 第 \(row) 行格式无效。" : "CSV row \(row) has an invalid format."
    }
    static func openAICSVMissingRequiredValue(_ row: Int) -> String {
        zh ? "CSV 第 \(row) 行缺少必填字段。" : "CSV row \(row) is missing required fields."
    }
    static func openAICSVInvalidAccount(_ row: Int) -> String {
        zh ? "CSV 第 \(row) 行的 token 校验失败。" : "CSV row \(row) failed token validation."
    }
    static func openAICSVAccountIDMismatch(_ row: Int) -> String {
        zh ? "CSV 第 \(row) 行的 account_id 校验失败。" : "CSV row \(row) failed account_id validation."
    }
    static func openAICSVEmailMismatch(_ row: Int) -> String {
        zh ? "CSV 第 \(row) 行的 email 校验失败。" : "CSV row \(row) failed email validation."
    }
    static var openAICSVDuplicateAccounts: String { zh ? "CSV 中存在重复的 account_id。" : "The CSV contains duplicate account_id values." }
    static var openAICSVMultipleActiveAccounts: String { zh ? "CSV 中包含多个 is_active=true 的账号。" : "The CSV contains multiple accounts marked as is_active=true." }
    static func openAICSVInvalidActiveValue(_ row: Int) -> String {
        zh ? "CSV 第 \(row) 行的 is_active 值无效。" : "CSV row \(row) has an invalid is_active value."
    }
    static var quit: String            { zh ? "退出"               : "Quit" }
    static var cancel: String          { zh ? "取消"               : "Cancel" }
    static var copied: String          { zh ? "已复制"             : "Copied" }
    static var justUpdated: String     { zh ? "刚刚更新"            : "Just updated" }
    static var authRecoveryDeferredMsg: String {
        zh ? "授权恢复尚未完成，请稍后再试" : "Auth recovery is not finished yet. Please try again shortly."
    }
    static var authValidationFailedMsg: String {
        zh ? "授权校验失败，请稍后重试" : "Authorization check failed. Please try again later."
    }

    static func available(_ n: Int, _ total: Int) -> String {
        zh ? "\(n)/\(total) 可用" : "\(n)/\(total) Available"
    }
    static func minutesAgo(_ m: Int) -> String {
        zh ? "\(m) 分钟前更新" : "Updated \(m) min ago"
    }
    static func hoursAgo(_ h: Int) -> String {
        zh ? "\(h) 小时前更新" : "Updated \(h) hr ago"
    }
    // MARK: - AccountRowView
    static var reauth: String          { zh ? "重新授权"     : "Re-authorize" }
    static var useBtn: String          { zh ? "使用"         : "Use" }
    static var switchBtn: String       { useBtn }
    static var tokenExpiredMsg: String { zh ? "Token 已过期，请重新授权" : "Token expired, please re-authorize" }
    static var bannedMsg: String       { zh ? "账号已停用"   : "Account suspended" }
    static var deleteBtn: String       { zh ? "删除"         : "Delete" }
    static var deleteConfirm: String   { zh ? "删除"         : "Delete" }
    static var nextUseTitle: String    { zh ? "下一次使用"   : "Next Use" }
    static var inUseNone: String       { zh ? "未检测到正在使用的 OpenAI 会话" : "No live OpenAI sessions detected" }
    static var runningThreadNone: String { zh ? "未检测到运行中的 OpenAI 线程" : "No running OpenAI threads detected" }
    static var runningThreadUnavailable: String { zh ? "运行中状态不可用" : "Running status unavailable" }
    static var runningThreadUnavailableRuntimeLogMissing: String {
        zh ? "运行中状态不可用（未找到运行日志库）" : "Running status unavailable (runtime log database missing)"
    }
    static var runningThreadUnavailableRuntimeLogUninitialized: String {
        zh ? "运行中状态不可用（运行日志库未初始化）" : "Running status unavailable (runtime logs not initialized)"
    }

    static func inUseSessions(_ count: Int) -> String {
        zh ? "使用中 · \(count) 个会话" : "In Use · \(count) session\(count == 1 ? "" : "s")"
    }

    static func runningThreads(_ count: Int) -> String {
        zh ? "运行 \(count)" : "Running \(count)"
    }

    static func inUseSummary(_ sessions: Int, _ accounts: Int) -> String {
        if zh {
            return "使用中 · \(sessions) 个会话 / \(accounts) 个账号"
        }
        return "In Use · \(sessions) session\(sessions == 1 ? "" : "s") across \(accounts) account\(accounts == 1 ? "" : "s")"
    }

    static func runningThreadSummary(_ threads: Int, _ accounts: Int) -> String {
        if zh {
            return "运行中 · \(threads) 个线程 / \(accounts) 个账号"
        }
        return "Running · \(threads) thread\(threads == 1 ? "" : "s") / \(accounts) account\(accounts == 1 ? "" : "s")"
    }

    static func inUseUnknownSessions(_ count: Int) -> String {
        zh ? "另有 \(count) 个未归因会话" : "\(count) unattributed session\(count == 1 ? "" : "s")"
    }

    static func runningThreadUnknown(_ count: Int) -> String {
        zh ? "另有 \(count) 个未归因线程" : "\(count) unattributed thread\(count == 1 ? "" : "s")"
    }

    static func openAIRouteSummaryCompact(_ value: String) -> String {
        zh ? "约\(value)" : "~\(value)"
    }

    static var delete: String         { zh ? "删除"     : "Delete" }
    static var tokenExpiredHint: String { zh ? "Token 已过期，请重新授权" : "Token expired, please re-authorize" }
    static var accountSuspended: String { zh ? "账号已停用" : "Account suspended" }
    static var weeklyExhausted: String  { zh ? "周额度耗尽" : "Weekly quota exhausted" }
    static var primaryExhausted: String { zh ? "5h 额度耗尽" : "5h quota exhausted" }
    nonisolated static func compactResetDaysHours(_ days: Int, _ hours: Int) -> String {
        zh ? "\(days)天\(hours)时" : "\(days)d \(hours)h"
    }
    nonisolated static func compactResetHoursMinutes(_ hours: Int, _ minutes: Int) -> String {
        zh ? "\(hours)时\(minutes)分" : "\(hours)h \(minutes)m"
    }
    nonisolated static func compactResetMinutes(_ minutes: Int) -> String {
        zh ? "\(minutes)分" : "\(minutes)m"
    }
    nonisolated static var compactResetSoon: String {
        zh ? "1分内" : "<1m"
    }

    // MARK: - TokenAccount status
    static var statusOk: String       { zh ? "正常"     : "OK" }
    static var statusWarning: String  { zh ? "即将用尽" : "Warning" }
    static var statusExceeded: String { zh ? "额度耗尽" : "Exceeded" }
    static var statusBanned: String   { zh ? "已停用"   : "Suspended" }

    // MARK: - Reset countdown
    static var resetSoon: String { zh ? "即将重置" : "Resetting soon" }
    static func resetInMin(_ m: Int) -> String {
        zh ? "\(m) 分钟后重置" : "Resets in \(m) min"
    }
    static func resetInHr(_ h: Int, _ m: Int) -> String {
        zh ? "\(h) 小时 \(m) 分后重置" : "Resets in \(h)h \(m)m"
    }
    static func resetInDay(_ d: Int, _ h: Int) -> String {
        zh ? "\(d) 天 \(h) 小时后重置" : "Resets in \(d)d \(h)h"
    }
}
