import Foundation
import XCTest

@MainActor
final class TokenStoreSettingsTests: CodexBarTestCase {
    func testSaveOpenAIAccountSettingsWritesAccountOrderModeAndManualActivationBehavior() throws {
        let store = TokenStore.shared
        store.load()
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_alpha", email: "alpha@example.com"))
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_beta", email: "beta@example.com"))

        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_beta", "acct_alpha"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .manual,
                manualActivationBehavior: .launchNewInstance
            )
        )

        XCTAssertEqual(store.config.openAI.accountOrder, ["acct_beta", "acct_alpha"])
        XCTAssertEqual(store.config.openAI.accountOrderingMode, .manual)
        XCTAssertEqual(store.config.openAI.manualActivationBehavior, .launchNewInstance)
    }

    func testSaveOpenAIUsageSettingsOnlyTouchesUsageFields() throws {
        let store = TokenStore.shared
        store.load()
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_alpha", email: "alpha@example.com"))
        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_alpha"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .manual,
                manualActivationBehavior: .launchNewInstance
            )
        )

        try store.saveOpenAIUsageSettings(
            OpenAIUsageSettingsUpdate(
                usageDisplayMode: .remaining,
                plusRelativeWeight: 6,
                proRelativeToPlusMultiplier: 14,
                teamRelativeToPlusMultiplier: 2
            )
        )

        XCTAssertEqual(store.config.openAI.usageDisplayMode, .remaining)
        XCTAssertEqual(store.config.openAI.quotaSort.plusRelativeWeight, 6)
        XCTAssertEqual(store.config.openAI.quotaSort.proRelativeToPlusMultiplier, 14)
        XCTAssertEqual(store.config.openAI.quotaSort.teamRelativeToPlusMultiplier, 2)
        XCTAssertEqual(store.config.openAI.accountOrder, ["acct_alpha"])
        XCTAssertEqual(store.config.openAI.accountOrderingMode, .manual)
        XCTAssertEqual(store.config.openAI.manualActivationBehavior, .launchNewInstance)
    }

    func testSaveDesktopSettingsOnlyTouchesPreferredPath() throws {
        let store = TokenStore.shared
        store.load()
        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: [],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .quotaSort,
                manualActivationBehavior: .launchNewInstance
            )
        )

        let validAppURL = try self.makeValidCodexApp(named: "Test/Codex.app")
        try store.saveDesktopSettings(
            DesktopSettingsUpdate(preferredCodexAppPath: validAppURL.path)
        )

        XCTAssertEqual(store.config.desktop.preferredCodexAppPath, validAppURL.path)
        XCTAssertEqual(store.config.openAI.accountOrderingMode, .quotaSort)
        XCTAssertEqual(store.config.openAI.manualActivationBehavior, .launchNewInstance)
    }

    func testRestoreActiveSelectionPersistsPreviousCompatibleProvider() throws {
        let store = TokenStore.shared
        store.load()

        try store.addCustomProvider(
            label: "Provider A",
            baseURL: "https://a.example.com/v1",
            accountLabel: "Alpha",
            apiKey: "sk-provider-a"
        )
        let providerA = try XCTUnwrap(store.activeProvider)
        let accountA = try XCTUnwrap(store.activeProviderAccount)

        try store.addCustomProvider(
            label: "Provider B",
            baseURL: "https://b.example.com/v1",
            accountLabel: "Beta",
            apiKey: "sk-provider-b"
        )
        XCTAssertEqual(store.activeProvider?.label, "Provider B")

        try store.restoreActiveSelection(
            activeProviderID: providerA.id,
            activeAccountID: accountA.id
        )

        XCTAssertEqual(store.activeProvider?.id, providerA.id)
        XCTAssertEqual(store.activeProviderAccount?.id, accountA.id)
    }

    func testAddCustomProviderNamedOpenRouterAvoidsReservedProviderID() throws {
        let store = TokenStore.shared
        store.load()

        try store.addCustomProvider(
            label: "OpenRouter",
            baseURL: "https://relay.example.com/v1",
            accountLabel: "Relay",
            apiKey: "sk-relay"
        )

        XCTAssertEqual(store.activeProvider?.kind, .openAICompatible)
        XCTAssertEqual(store.activeProvider?.id, "openrouter-custom")
    }

    private func makeValidCodexApp(named relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
        let appURL = root.appendingPathComponent(relativePath)
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let executableURL = resourcesURL.appendingPathComponent("codex")
        try Data().write(to: executableURL)
        return appURL
    }
}
