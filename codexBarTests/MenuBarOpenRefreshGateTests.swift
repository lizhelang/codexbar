import XCTest

final class MenuBarOpenRefreshGateTests: XCTestCase {
    func testFirstOpenTriggersRefreshWhenIdle() {
        var gate = MenuBarOpenRefreshGate()

        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false))
    }

    func testSecondOpenInSamePresentationDoesNotTriggerAgain() {
        var gate = MenuBarOpenRefreshGate()

        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false))
        XCTAssertFalse(gate.shouldTriggerRefresh(isRefreshing: false))
    }

    func testCloseResetsGateForNextOpen() {
        var gate = MenuBarOpenRefreshGate()

        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false))
        gate.resetForClose()

        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false))
    }

    func testOpenWhileRefreshAlreadyRunningStillConsumesPresentation() {
        var gate = MenuBarOpenRefreshGate()

        XCTAssertFalse(gate.shouldTriggerRefresh(isRefreshing: true))
        XCTAssertFalse(gate.shouldTriggerRefresh(isRefreshing: false))
        gate.resetForClose()
        XCTAssertTrue(gate.shouldTriggerRefresh(isRefreshing: false))
    }
}
