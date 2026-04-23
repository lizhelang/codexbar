import Foundation
import XCTest

@MainActor
final class OpenAIAccountCSVPanelServiceTests: XCTestCase {
    func testExportRequestsSavePanelAfterActivation() {
        var didActivate = false
        var didRequestSavePanel = false
        let expectedURL = URL(fileURLWithPath: "/tmp/export.csv")
        let service = OpenAIAccountCSVPanelService(
            activateApp: { didActivate = true },
            requestExportURLAction: { _ in
                didRequestSavePanel = true
                return expectedURL
            },
            requestImportURLAction: { nil }
        )

        XCTAssertEqual(service.requestExportURL(), expectedURL)
        XCTAssertTrue(didActivate)
        XCTAssertTrue(didRequestSavePanel)
    }

    func testExportPassesSuggestedJSONFilenameToSavePanel() {
        var receivedFilename: String?
        let expectedURL = URL(fileURLWithPath: "/tmp/export.csv")
        let service = OpenAIAccountCSVPanelService(
            activateApp: {},
            requestExportURLAction: { suggestedFilename in
                receivedFilename = suggestedFilename
                return expectedURL
            },
            requestImportURLAction: { nil }
        )

        XCTAssertEqual(service.requestExportURL(), expectedURL)
        XCTAssertEqual(receivedFilename?.hasPrefix("rhino2api-account-"), true)
        XCTAssertEqual(receivedFilename?.hasSuffix(".json"), true)
    }

    func testImportCancelReturnsNil() {
        var didActivate = false
        let service = OpenAIAccountCSVPanelService(
            activateApp: { didActivate = true },
            requestExportURLAction: { _ in nil },
            requestImportURLAction: { nil }
        )

        XCTAssertNil(service.requestImportURL())
        XCTAssertTrue(didActivate)
    }

    func testToolbarConstantsStayStable() {
        XCTAssertEqual(OpenAIAccountCSVToolbarUI.symbolName, "arrow.up.arrow.down.circle")
        XCTAssertEqual(OpenAIAccountCSVToolbarUI.accessibilityIdentifier, "codexbar.openai-csv.toolbar")
    }
}
