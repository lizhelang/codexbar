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
