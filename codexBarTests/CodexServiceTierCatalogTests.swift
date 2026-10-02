import XCTest
@testable import codexbar

final class CodexServiceTierCatalogTests: CodexBarTestCase {
    func testParseReadsPerModelServiceTiersFromCodexModelsCache() throws {
        let catalog = try CodexServiceTierCatalog.parse(Self.fixture(
            models: [
                Self.model("gpt-5.6-sol", tiers: [("priority", "Fast")]),
                Self.model("gpt-6-astra", tiers: [("priority", "Fast"), ("ultrafast", "Ultrafast")]),
                Self.model("gpt-5.5", tiers: []),
            ]
        ))

        XCTAssertEqual(catalog.models.map(\.slug), ["gpt-5.6-sol", "gpt-6-astra", "gpt-5.5"])
        XCTAssertEqual(catalog.serviceTierOptions(for: "gpt-5.6-sol"), ["standard", "fast"])
        XCTAssertEqual(catalog.serviceTierOptions(for: "GPT-6-Astra "), ["standard", "fast", "ultrafast"])
        XCTAssertEqual(catalog.serviceTierOptions(for: "gpt-5.5"), ["standard"])
        XCTAssertNil(catalog.serviceTierOptions(for: "gpt-unknown"))
        XCTAssertEqual(catalog.fetchedAt, ISO8601Parsing.parse("2026-09-26T04:14:16Z"))
    }

    func testParseSkipsMalformedModelEntriesWithoutFailingWholeCatalog() throws {
        let json = """
        {
          "fetched_at": "2026-09-26T04:14:16.319744Z",
          "models": [
            {"slug": "gpt-5.6-sol", "service_tiers": [{"id": "priority", "name": "Fast", "description": ""}]},
            {"display_name": "missing slug"},
            "not-an-object"
          ]
        }
        """
        let catalog = try CodexServiceTierCatalog.parse(Data(json.utf8))

        XCTAssertEqual(catalog.models.map(\.slug), ["gpt-5.6-sol"])
    }

    func testCatalogDrivesVisibleModelsReasoningAndContext() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "models": [
                ["slug": "gpt-6-sol", "visibility": "list", "context_window": 272000,
                 "max_context_window": 872000,
                 "default_reasoning_level": "medium",
                 "supported_reasoning_levels": [["effort": "low"], ["effort": "medium"], ["effort": "ultra"]]],
                ["slug": "gpt-reserve", "visibility": "hide", "context_window": 272000,
                 "supported_reasoning_levels": [["effort": "low"]]],
            ],
        ])
        let catalog = try CodexServiceTierCatalog.parse(data)

        XCTAssertEqual(catalog.selectableModelIDs, ["gpt-6-sol"])
        XCTAssertEqual(catalog.reasoningEffortOptions(for: "gpt-6-sol"), ["low", "medium", "ultra"])
        XCTAssertEqual(catalog.model(for: "gpt-6-sol")?.maxContextWindow, 872000)
        XCTAssertEqual(CodexBarGlobalSettings.compatibleReasoningEffort("high", for: "gpt-6-sol", catalog: catalog), "medium")
        XCTAssertFalse(CodexBarGlobalSettings.supportsReasoningEffort("high", for: "gpt-6-sol", catalog: catalog))
        XCTAssertEqual(CodexBarGlobalSettings().displayContextWindow(for: "gpt-6-sol", catalog: catalog), 272000)
        XCTAssertNil(CodexBarGlobalSettings().syncContextWindow(for: "gpt-6-sol"))
        XCTAssertEqual(CodexBarGlobalSettings(modelContextWindows: ["gpt-6-sol": 512000]).syncContextWindow(for: "gpt-6-sol"), 512000)
    }

    func testLoadReturnsNilWhenCacheIsMissingOrCorrupt() throws {
        XCTAssertNil(CodexServiceTierCatalog.load())

        try CodexPaths.ensureDirectories()
        try Data("{not json".utf8).write(to: CodexPaths.modelsCacheURL)
        XCTAssertNil(CodexServiceTierCatalog.load())
    }

    func testGlobalSettingsFallBackToBuiltinOptionsWithoutCatalog() {
        XCTAssertEqual(
            CodexBarGlobalSettings.serviceTierOptions(for: "gpt-5.6-sol", catalog: nil),
            ["standard", "fast"]
        )
        XCTAssertEqual(
            CodexBarGlobalSettings.compatibleServiceTier("ultrafast", for: "gpt-5.6-sol", catalog: nil),
            "standard"
        )
        XCTAssertEqual(
            CodexBarGlobalSettings.compatibleServiceTier("flex", for: "gpt-5.6-sol", catalog: nil),
            "standard"
        )
        XCTAssertEqual(
            CodexBarGlobalSettings.compatibleServiceTier("priority", for: "gpt-5.6-sol", catalog: nil),
            "fast"
        )
    }

    func testGlobalSettingsFollowCatalogWhenModelDropsOrGainsTiers() throws {
        let catalog = try CodexServiceTierCatalog.parse(Self.fixture(
            models: [
                Self.model("gpt-5.5", tiers: []),
                Self.model("gpt-6-astra", tiers: [("priority", "Fast"), ("ultrafast", "Ultrafast")]),
            ]
        ))

        XCTAssertEqual(
            CodexBarGlobalSettings.serviceTierOptions(for: "gpt-5.5", catalog: catalog),
            ["standard"]
        )
        XCTAssertEqual(
            CodexBarGlobalSettings.compatibleServiceTier("fast", for: "gpt-5.5", catalog: catalog),
            "standard"
        )
        XCTAssertEqual(
            CodexBarGlobalSettings.compatibleServiceTier("ultrafast", for: "gpt-6-astra", catalog: catalog),
            "ultrafast"
        )
        XCTAssertTrue(CodexBarGlobalSettings.supportsServiceTier("ultrafast", for: "gpt-6-astra", catalog: catalog))
        XCTAssertFalse(CodexBarGlobalSettings.supportsServiceTier("ultrafast", for: "gpt-5.5", catalog: catalog))
    }

    func testCodexConfigServiceTierWritesOnlySupportedTiers() throws {
        let catalog = try CodexServiceTierCatalog.parse(Self.fixture(
            models: [
                Self.model("gpt-5.5", tiers: []),
                Self.model("gpt-6-astra", tiers: [("priority", "Fast"), ("ultrafast", "Ultrafast")]),
                Self.model("gpt-defaulted", tiers: [("priority", "Fast")], defaultTier: "priority"),
            ]
        ))

        XCTAssertNil(
            CodexBarGlobalSettings(serviceTier: "standard").codexConfigServiceTier(for: "gpt-6-astra", catalog: catalog)
        )
        XCTAssertEqual(
            CodexBarGlobalSettings(serviceTier: "fast").codexConfigServiceTier(for: "gpt-6-astra", catalog: catalog),
            "fast"
        )
        XCTAssertEqual(
            CodexBarGlobalSettings(serviceTier: "ultrafast").codexConfigServiceTier(for: "gpt-6-astra", catalog: catalog),
            "ultrafast"
        )
        XCTAssertNil(
            CodexBarGlobalSettings(serviceTier: "fast").codexConfigServiceTier(for: "gpt-5.5", catalog: catalog),
            "模型不再支持 fast 时应回落为标准路由并删键"
        )
        XCTAssertEqual(
            CodexBarGlobalSettings(serviceTier: "standard").codexConfigServiceTier(for: "gpt-defaulted", catalog: catalog),
            "default",
            "目录声明了默认档位时，标准路由需要显式写 default 哨兵值"
        )
        XCTAssertNil(
            CodexBarGlobalSettings(serviceTier: "flex").codexConfigServiceTier(for: "gpt-6-astra", catalog: nil)
        )
    }

    func testNormalizedServiceTierAcceptsCatalogIdentifiersAndRejectsGarbage() {
        XCTAssertEqual(CodexBarGlobalSettings.normalizedServiceTier(" Flex "), "standard")
        XCTAssertEqual(CodexBarGlobalSettings.normalizedServiceTier("default"), "standard")
        XCTAssertEqual(CodexBarGlobalSettings.normalizedServiceTier("priority"), "fast")
        XCTAssertEqual(CodexBarGlobalSettings.normalizedServiceTier("ultrafast"), "ultrafast")
        XCTAssertEqual(CodexBarGlobalSettings.normalizedServiceTier("tier_2-beta"), "tier_2-beta")
        XCTAssertNil(CodexBarGlobalSettings.normalizedServiceTier(""))
        XCTAssertNil(CodexBarGlobalSettings.normalizedServiceTier("fast mode"))
        XCTAssertNil(CodexBarGlobalSettings.normalizedServiceTier("\"fast\""))
        XCTAssertNil(CodexBarGlobalSettings.normalizedServiceTier("-fast"))
    }

    // MARK: - Fixtures

    static func model(
        _ slug: String,
        tiers: [(String, String)],
        defaultTier: String? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "slug": slug,
            "display_name": slug,
            "supported_reasoning_levels": [["effort": "medium", "description": ""]],
            "additional_speed_tiers": tiers.isEmpty ? [] : ["fast"],
            "service_tiers": tiers.map { ["id": $0.0, "name": $0.1, "description": "\($0.1) tier"] },
        ]
        entry["default_service_tier"] = defaultTier ?? NSNull()
        return entry
    }

    static func fixture(models: [[String: Any]]) -> Data {
        let payload: [String: Any] = [
            "fetched_at": "2026-09-26T04:14:16.000000Z",
            "etag": "W/\"fixture\"",
            "client_version": "0.158.0",
            "models": models,
        ]
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    static func writeFixture(models: [[String: Any]]) throws {
        try CodexPaths.ensureDirectories()
        try Self.fixture(models: models).write(to: CodexPaths.modelsCacheURL)
    }
}
