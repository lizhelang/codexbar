import AppKit
import XCTest

@MainActor
final class MenuBarInitialFocusTests: XCTestCase {
    func testOpeningClearsAutomaticControlFocusWithoutBreakingTabNavigation() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let iconButton = KeyboardFocusableButton(frame: NSRect(x: 0, y: 50, width: 80, height: 25))
        let nextButton = KeyboardFocusableButton(frame: NSRect(x: 100, y: 50, width: 80, height: 25))
        window.contentView?.addSubview(iconButton)
        window.contentView?.addSubview(nextButton)
        window.autorecalculatesKeyViewLoop = false
        window.initialFirstResponder = iconButton
        iconButton.nextKeyView = nextButton
        nextButton.nextKeyView = iconButton

        XCTAssertTrue(window.makeFirstResponder(iconButton))
        MenuBarStatusItemController.clearInitialKeyboardFocus(in: window)
        XCTAssertTrue(window.firstResponder === window)

        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === iconButton)
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === nextButton)

        // 再次打开也不应恢复上次选中的按钮。
        MenuBarStatusItemController.clearInitialKeyboardFocus(in: window)
        XCTAssertTrue(window.firstResponder === window)
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === iconButton)
        window.selectPreviousKeyView(nil)
        XCTAssertTrue(window.firstResponder === nextButton)
    }
}

/// 模拟启用键盘导航时的按钮，无需读写测试机器的系统偏好。
private final class KeyboardFocusableButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}
