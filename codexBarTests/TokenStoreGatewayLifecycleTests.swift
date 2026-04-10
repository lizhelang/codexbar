import Foundation
import XCTest

@MainActor
final class TokenStoreGatewayLifecycleTests: CodexBarTestCase {
    func testSwitchModeInitializationKeepsGatewayStopped() {
        let gateway = OpenAIAccountGatewayControllerSpy()

        _ = TokenStore(openAIAccountGatewayService: gateway)

        XCTAssertEqual(gateway.startCount, 0)
        XCTAssertEqual(gateway.stopCount, 1)
        XCTAssertEqual(gateway.updatedModes, [.switchAccount])
    }

    func testAggregateModeInitializationStartsGateway() throws {
        var config = CodexBarConfig()
        config.openAI.accountUsageMode = .aggregateGateway
        try self.writeConfig(config)

        let gateway = OpenAIAccountGatewayControllerSpy()

        _ = TokenStore(openAIAccountGatewayService: gateway)

        XCTAssertEqual(gateway.startCount, 1)
        XCTAssertEqual(gateway.stopCount, 0)
        XCTAssertEqual(gateway.updatedModes, [.aggregateGateway])
    }

    func testUpdatingUsageModeStartsAndStopsGateway() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let store = TokenStore(openAIAccountGatewayService: gateway)
        let account = try self.makeOAuthAccount(
            accountID: "acct-gateway",
            email: "gateway@example.com"
        )

        store.addOrUpdate(account)
        try store.activate(account)

        let initialStopCount = gateway.stopCount
        let initialUpdateCount = gateway.updatedModes.count

        try store.updateOpenAIAccountUsageMode(.aggregateGateway)
        XCTAssertEqual(gateway.startCount, 1)
        XCTAssertEqual(gateway.stopCount, initialStopCount)
        XCTAssertEqual(gateway.updatedModes.suffix(1).first, .aggregateGateway)

        try store.updateOpenAIAccountUsageMode(.switchAccount)
        XCTAssertEqual(gateway.startCount, 1)
        XCTAssertEqual(gateway.stopCount, initialStopCount + 1)
        XCTAssertEqual(gateway.updatedModes.count, initialUpdateCount + 2)
        XCTAssertEqual(gateway.updatedModes.suffix(1).first, .switchAccount)
    }

    private func writeConfig(_ config: CodexBarConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try CodexPaths.writeSecureFile(data, to: CodexPaths.barConfigURL)
    }
}

private final class OpenAIAccountGatewayControllerSpy: OpenAIAccountGatewayControlling {
    var startCount = 0
    var stopCount = 0
    var updatedModes: [CodexBarOpenAIAccountUsageMode] = []

    func startIfNeeded() {
        self.startCount += 1
    }

    func stop() {
        self.stopCount += 1
    }

    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode
    ) {
        self.updatedModes.append(accountUsageMode)
    }
}
