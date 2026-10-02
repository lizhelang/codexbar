import Foundation

/// Display and collector preferences only. Account credentials remain in the existing account store.
nonisolated struct ApplicationPreferences: Codable, Equatable, Sendable {
    enum Language: String, Codable, CaseIterable, Sendable { case system, simplifiedChinese, english }
    enum Theme: String, Codable, CaseIterable, Sendable { case system, light, dark }
    enum AccentColor: String, Codable, CaseIterable, Sendable { case teal, blue, green, orange, purple }
    enum AccountIdentityDisplay: String, CaseIterable, Sendable { case email, name }

    static let allPages = ["home", "limits", "tools", "models", "projects", "sessions", "devices", "trends"]
    static let allHomeModules = ["limits", "tools", "models", "sessions", "activity", "devices", "trends"]
    static let allTools = ["codex", "claudeCode", "openCode", "cursor", "deepSeekHarness"]

    var showAppIcon = true
    var showTokenRate = true
    var showToolIcons = true
    var hideAccountEmail = false
    var defaultUsageMetric = "tokens"
    var modelAliases: [String: String] = [:]
    var displayCurrencyCode = "USD"
    var usdExchangeRate: Double = 1
    var quotaRefreshIntervalSeconds: Double = 60
    var scheduledExportEnabled = false
    var scheduledExportDirectory = ""
    var scheduledExportIntervalSeconds: Double = 86400
    var language: Language = .system
    var automaticUpdateChecks = true
    var automaticallyDownloadUpdates = false
    var homeModuleOrder = Self.allHomeModules
    var hiddenHomeModules = ["tools", "devices"]
    var pageOrder = Self.allPages
    var hiddenPages: [String] = []
    var homeItemLimit = 5
    var defaultUsageRange = "today"
    var preferredMenuHeight: Double = 0
    var keepMenuOpenOnOutsideClick = false
    var theme: Theme = .dark
    var accentColor: AccentColor = .teal
    var backgroundOpacity: Double = 1
    var fontScale: Double = 1
    var toolOrder = Self.allTools
    var disabledTools: [String] = []
    var refreshIntervalSeconds: Double = 90
    /// Tool data roots, not credentials. Empty entries use the tool's standard location.
    var customDataDirectories: [String: String] = [:]

    init() {}

    var visiblePages: [String] { self.pageOrder.filter { !self.hiddenPages.contains($0) } }
    var visibleHomeModules: [String] { self.homeModuleOrder.filter { !self.hiddenHomeModules.contains($0) } }
    var enabledTools: [String] { self.toolOrder.filter { !self.disabledTools.contains($0) } }

    /// Keep the existing privacy preference as the sole persisted value.
    var accountIdentityDisplay: AccountIdentityDisplay {
        get { self.hideAccountEmail ? .name : .email }
        set { self.hideAccountEmail = newValue == .name }
    }

    func accountIdentity(
        email: String,
        displayName: String?,
        username: String?,
        organizationName: String? = nil,
        accountID: String
    ) -> String {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.accountIdentityDisplay == .email, !email.isEmpty { return email }

        for candidate in [displayName, username, organizationName] {
            guard let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !name.contains("@") else { continue }
            return name
        }

        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty, !accountID.contains("@") else { return "—" }
        return "…" + accountID.suffix(6)
    }

    func dataDirectory(for tool: String) -> URL? {
        guard let path = self.customDataDirectories[tool]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
    }

    mutating func normalize() {
        self.pageOrder = Self.normalizedOrder(self.pageOrder, allowed: Self.allPages)
        self.homeModuleOrder = Self.normalizedOrder(self.homeModuleOrder, allowed: Self.allHomeModules)
        self.toolOrder = Self.normalizedOrder(self.toolOrder, allowed: Self.allTools)
        self.hiddenPages = self.hiddenPages.filter { Self.allPages.contains($0) && $0 != "home" }
        self.hiddenHomeModules = self.hiddenHomeModules.filter(Self.allHomeModules.contains)
        self.disabledTools = self.disabledTools.filter(Self.allTools.contains)
        self.homeItemLimit = min(20, max(1, self.homeItemLimit))
        if !["tokens", "cost"].contains(self.defaultUsageMetric) { self.defaultUsageMetric = "tokens" }
        if !["USD", "CNY", "HKD", "TWD", "AUD", "EUR", "JPY"].contains(self.displayCurrencyCode) { self.displayCurrencyCode = "USD" }
        self.usdExchangeRate = self.usdExchangeRate.isFinite ? min(100000, max(0.000001, self.usdExchangeRate)) : 1
        self.quotaRefreshIntervalSeconds = self.quotaRefreshIntervalSeconds.isFinite
            ? min(3600, max(60, self.quotaRefreshIntervalSeconds)) : 60
        self.scheduledExportIntervalSeconds = self.scheduledExportIntervalSeconds.isFinite
            ? min(604800, max(300, self.scheduledExportIntervalSeconds)) : 86400
        self.modelAliases = self.modelAliases.filter { !$0.key.isEmpty && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !["today", "thisWeek", "thisMonth", "allTime", "last7Days", "last30Days"].contains(self.defaultUsageRange) {
            self.defaultUsageRange = "today"
        }
        self.preferredMenuHeight = self.preferredMenuHeight.isFinite && self.preferredMenuHeight > 0
            ? min(1600, max(260, self.preferredMenuHeight)) : 0
        self.backgroundOpacity = self.backgroundOpacity.isFinite ? min(1, max(0.35, self.backgroundOpacity)) : 1
        self.fontScale = self.fontScale.isFinite ? min(1.3, max(0.85, self.fontScale)) : 1
        self.refreshIntervalSeconds = self.refreshIntervalSeconds.isFinite
            ? min(3600, max(30, self.refreshIntervalSeconds)) : 90
        self.customDataDirectories = self.customDataDirectories.filter { Self.allTools.contains($0.key) }
    }

    private static func normalizedOrder(_ order: [String], allowed: [String]) -> [String] {
        var seen = Set<String>()
        return (order + allowed).filter { allowed.contains($0) && seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case language, automaticUpdateChecks, automaticallyDownloadUpdates, homeModuleOrder, hiddenHomeModules
        case pageOrder, hiddenPages, homeItemLimit, defaultUsageRange, preferredMenuHeight, keepMenuOpenOnOutsideClick
        case theme, accentColor, backgroundOpacity, fontScale, toolOrder, disabledTools, refreshIntervalSeconds
        case customDataDirectories
        case showAppIcon, showTokenRate, showToolIcons, hideAccountEmail, defaultUsageMetric, modelAliases
        case displayCurrencyCode, usdExchangeRate, quotaRefreshIntervalSeconds
        case scheduledExportEnabled, scheduledExportDirectory, scheduledExportIntervalSeconds
    }

    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.language = try c.decodeIfPresent(Language.self, forKey: .language) ?? self.language
        self.automaticUpdateChecks = try c.decodeIfPresent(Bool.self, forKey: .automaticUpdateChecks) ?? self.automaticUpdateChecks
        self.automaticallyDownloadUpdates = try c.decodeIfPresent(Bool.self, forKey: .automaticallyDownloadUpdates) ?? self.automaticallyDownloadUpdates
        self.homeModuleOrder = try c.decodeIfPresent([String].self, forKey: .homeModuleOrder) ?? self.homeModuleOrder
        self.hiddenHomeModules = try c.decodeIfPresent([String].self, forKey: .hiddenHomeModules) ?? self.hiddenHomeModules
        self.pageOrder = try c.decodeIfPresent([String].self, forKey: .pageOrder) ?? self.pageOrder
        self.hiddenPages = try c.decodeIfPresent([String].self, forKey: .hiddenPages) ?? self.hiddenPages
        self.homeItemLimit = try c.decodeIfPresent(Int.self, forKey: .homeItemLimit) ?? self.homeItemLimit
        self.defaultUsageRange = try c.decodeIfPresent(String.self, forKey: .defaultUsageRange) ?? self.defaultUsageRange
        self.preferredMenuHeight = try c.decodeIfPresent(Double.self, forKey: .preferredMenuHeight) ?? self.preferredMenuHeight
        self.keepMenuOpenOnOutsideClick = try c.decodeIfPresent(Bool.self, forKey: .keepMenuOpenOnOutsideClick) ?? self.keepMenuOpenOnOutsideClick
        self.theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? self.theme
        self.accentColor = try c.decodeIfPresent(AccentColor.self, forKey: .accentColor) ?? self.accentColor
        self.backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? self.backgroundOpacity
        self.fontScale = try c.decodeIfPresent(Double.self, forKey: .fontScale) ?? self.fontScale
        self.toolOrder = try c.decodeIfPresent([String].self, forKey: .toolOrder) ?? self.toolOrder
        self.disabledTools = try c.decodeIfPresent([String].self, forKey: .disabledTools) ?? self.disabledTools
        self.refreshIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .refreshIntervalSeconds) ?? self.refreshIntervalSeconds
        self.customDataDirectories = try c.decodeIfPresent([String: String].self, forKey: .customDataDirectories) ?? self.customDataDirectories
        self.showAppIcon = try c.decodeIfPresent(Bool.self, forKey: .showAppIcon) ?? self.showAppIcon
        self.showTokenRate = try c.decodeIfPresent(Bool.self, forKey: .showTokenRate) ?? self.showTokenRate
        self.showToolIcons = try c.decodeIfPresent(Bool.self, forKey: .showToolIcons) ?? self.showToolIcons
        self.hideAccountEmail = try c.decodeIfPresent(Bool.self, forKey: .hideAccountEmail) ?? self.hideAccountEmail
        self.defaultUsageMetric = try c.decodeIfPresent(String.self, forKey: .defaultUsageMetric) ?? self.defaultUsageMetric
        self.modelAliases = try c.decodeIfPresent([String: String].self, forKey: .modelAliases) ?? self.modelAliases
        self.displayCurrencyCode = try c.decodeIfPresent(String.self, forKey: .displayCurrencyCode) ?? self.displayCurrencyCode
        self.usdExchangeRate = try c.decodeIfPresent(Double.self, forKey: .usdExchangeRate) ?? self.usdExchangeRate
        self.quotaRefreshIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .quotaRefreshIntervalSeconds) ?? self.quotaRefreshIntervalSeconds
        self.scheduledExportEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduledExportEnabled) ?? self.scheduledExportEnabled
        self.scheduledExportDirectory = try c.decodeIfPresent(String.self, forKey: .scheduledExportDirectory) ?? self.scheduledExportDirectory
        self.scheduledExportIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .scheduledExportIntervalSeconds) ?? self.scheduledExportIntervalSeconds
        self.normalize()
    }
}
