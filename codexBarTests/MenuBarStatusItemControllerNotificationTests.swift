import AppKit
import XCTest

@MainActor
final class MenuBarStatusItemControllerNotificationTests: XCTestCase {
    func testPopoverWillShowPostsMenuWillOpenNotification() {
        let controller = MenuBarStatusItemController.shared
        let expectation = expectation(
            forNotification: .codexbarStatusItemMenuWillOpen,
            object: controller
        )

        controller.popoverWillShow(Notification(name: NSPopover.willShowNotification))

        wait(for: [expectation], timeout: 0.1)
    }

    func testMenuReadyNotificationIsSeparateFromWillOpen() {
        let controller = MenuBarStatusItemController.shared
        var didOpen = false
        let observer = NotificationCenter.default.addObserver(
            forName: .codexbarStatusItemMenuDidOpen, object: controller, queue: nil
        ) { _ in didOpen = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.popoverWillShow(Notification(name: NSPopover.willShowNotification))
        XCTAssertFalse(didOpen)
        controller.popoverDidShow(Notification(name: NSPopover.didShowNotification))
        XCTAssertTrue(didOpen)
    }

    func testPopoverDidClosePostsMenuDidCloseNotification() {
        let controller = MenuBarStatusItemController.shared
        let expectation = expectation(
            forNotification: .codexbarStatusItemMenuDidClose,
            object: controller
        )

        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))

        wait(for: [expectation], timeout: 0.1)
    }
}
