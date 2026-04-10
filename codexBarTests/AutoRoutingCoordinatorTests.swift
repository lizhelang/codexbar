import Foundation
import XCTest

final class CodexBarConfigCompatibilityTests: CodexBarTestCase {
    func testConfigDecodesMissingDesktopWithDefaults() throws {
        let json = """
        {
          "version": 1,
          "global": {
            "defaultModel": "gpt-5.4",
            "reviewModel": "gpt-5.4",
            "reasoningEffort": "xhigh"
          },
          "active": {},
          "providers": []
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        let config = try JSONDecoder().decode(CodexBarConfig.self, from: data)

        XCTAssertNil(config.desktop.preferredCodexAppPath)
        XCTAssertEqual(config.openAI.usageDisplayMode, .used)
        XCTAssertEqual(config.openAI.quotaSort.plusRelativeWeight, 10)
        XCTAssertEqual(config.openAI.quotaSort.teamRelativeToPlusMultiplier, 1.5)
        XCTAssertEqual(config.openAI.accountOrder, [])
        XCTAssertEqual(config.openAI.accountOrderingMode, .quotaSort)
        XCTAssertEqual(config.openAI.manualActivationBehavior, .updateConfigOnly)
    }

    func testConfigDecodesLegacyAutoRoutingFieldsByIgnoringThem() throws {
        let json = """
        {
          "version": 1,
          "global": {
            "defaultModel": "gpt-5.4",
            "reviewModel": "gpt-5.4",
            "reasoningEffort": "xhigh"
          },
          "active": {},
          "autoRouting": {
            "enabled": true,
            "switchThresholdPercent": 15,
            "promptMode": "remindOnly"
          },
          "openAI": {
            "accountOrder": ["acct_a"],
            "popupAlertThresholdPercent": 25
          },
          "desktop": {},
          "providers": []
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        let config = try JSONDecoder().decode(CodexBarConfig.self, from: data)

        XCTAssertEqual(config.openAI.accountOrder, ["acct_a"])
        XCTAssertEqual(config.openAI.usageDisplayMode, .used)
        XCTAssertEqual(config.openAI.quotaSort.plusRelativeWeight, 10)
        XCTAssertEqual(config.openAI.quotaSort.teamRelativeToPlusMultiplier, 1.5)
        XCTAssertEqual(config.openAI.accountOrderingMode, .quotaSort)
        XCTAssertEqual(config.openAI.manualActivationBehavior, .updateConfigOnly)
        XCTAssertNil(config.desktop.preferredCodexAppPath)
    }

    func testPreferredDisplayAccountOrderOnlyAppliesInManualMode() {
        var settings = CodexBarOpenAISettings(
            accountOrder: ["acct_b", "acct_a"],
            accountOrderingMode: .quotaSort
        )

        XCTAssertEqual(settings.preferredDisplayAccountOrder, [])

        settings.accountOrderingMode = .manual
        XCTAssertEqual(settings.preferredDisplayAccountOrder, ["acct_b", "acct_a"])
    }

    @MainActor
    func testSaveDesktopSettingsRejectsInvalidCodexAppPath() throws {
        let invalidURL = try self.makeDirectory(named: "Invalid/Codex.app")
        TokenStore.shared.load()

        XCTAssertThrowsError(
            try TokenStore.shared.saveDesktopSettings(
                DesktopSettingsUpdate(preferredCodexAppPath: invalidURL.path)
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                TokenStoreError.invalidCodexAppPath.localizedDescription
            )
        }
    }

    func testAccountIsMarkedDegradedAtEightyPercent() {
        XCTAssertTrue(
            self.makeAccount(accountId: "acct_degraded", primaryUsedPercent: 80, secondaryUsedPercent: 10)
                .isDegradedForNextUseRouting
        )
        XCTAssertFalse(
            self.makeAccount(accountId: "acct_healthy", primaryUsedPercent: 79, secondaryUsedPercent: 10)
                .isDegradedForNextUseRouting
        )
    }

    private func makeDirectory(named relativePath: String) throws -> URL {
        let url = CodexPaths.realHome.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAccount(
        accountId: String,
        primaryUsedPercent: Double,
        secondaryUsedPercent: Double
    ) -> TokenAccount {
        TokenAccount(
            email: "\(accountId)@example.com",
            accountId: accountId,
            accessToken: "access-\(accountId)",
            refreshToken: "refresh-\(accountId)",
            idToken: "id-\(accountId)",
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent
        )
    }
}
