import XCTest

final class CodexBarOpenAIAccountUsageModeTests: XCTestCase {
    private var originalLanguageOverride: Bool?

    override func setUp() {
        super.setUp()
        self.originalLanguageOverride = L.languageOverride
    }

    override func tearDown() {
        L.languageOverride = self.originalLanguageOverride
        super.tearDown()
    }

    func testMenuToggleTitlesUseRequestedChineseCopy() {
        L.languageOverride = true

        XCTAssertEqual(CodexBarOpenAIAccountUsageMode.switchAccount.menuToggleTitle, "切换")
        XCTAssertEqual(CodexBarOpenAIAccountUsageMode.aggregateGateway.menuToggleTitle, "聚合")
    }

    func testMenuToggleTitlesUseCompactEnglishCopy() {
        L.languageOverride = false

        XCTAssertEqual(CodexBarOpenAIAccountUsageMode.switchAccount.menuToggleTitle, "Switch")
        XCTAssertEqual(CodexBarOpenAIAccountUsageMode.aggregateGateway.menuToggleTitle, "Aggregate")
    }

    func testUsageModeOrderKeepsSwitchOnTheLeftAndAggregateOnTheRight() {
        XCTAssertEqual(
            CodexBarOpenAIAccountUsageMode.allCases,
            [.switchAccount, .aggregateGateway]
        )
    }

    func testDecodesRemovedHybridProviderModeAsSwitchFallback() throws {
        let decoder = JSONDecoder()

        let removedHybrid = try decoder.decode(
            CodexBarOpenAISettings.self,
            from: Data(#"{"accountUsageMode":"hybrid_provider"}"#.utf8)
        )
        let unknown = try decoder.decode(
            CodexBarOpenAISettings.self,
            from: Data(#"{"accountUsageMode":"future_mode"}"#.utf8)
        )

        XCTAssertEqual(removedHybrid.accountUsageMode, .switchAccount)
        XCTAssertEqual(unknown.accountUsageMode, .switchAccount)
    }

    func testMenuBarUsageTextDefaultsOffAndRoundTripsWhenEnabled() throws {
        let decoder = JSONDecoder()
        let legacySettings = try decoder.decode(
            CodexBarOpenAISettings.self,
            from: Data(#"{"usageDisplayMode":"used"}"#.utf8)
        )

        XCTAssertFalse(legacySettings.showsMenuBarUsageText)

        let encoded = try JSONEncoder().encode(
            CodexBarOpenAISettings(showsMenuBarUsageText: true)
        )
        let restored = try decoder.decode(CodexBarOpenAISettings.self, from: encoded)

        XCTAssertTrue(restored.showsMenuBarUsageText)
    }

    func testHybridTargetSelectionNormalizesBlankFields() throws {
        let decoder = JSONDecoder()
        let settings = try decoder.decode(
            CodexBarOpenAISettings.self,
            from: Data(
                #"""
                {
                  "hybridTargetSelection": {
                    "providerId": " relay-provider ",
                    "accountId": " ",
                    "modelId": " anthropic/claude "
                  }
                }
                """#.utf8
            )
        )

        XCTAssertEqual(settings.hybridTargetSelection?.providerId, "relay-provider")
        XCTAssertNil(settings.hybridTargetSelection?.accountId)
        XCTAssertEqual(settings.hybridTargetSelection?.modelId, "anthropic/claude")
    }
}
