import AppKit
import XCTest

@MainActor
final class RouteSelectionMenuTests: XCTestCase {
    func testMenuRepresentsSelectionAndSeparatorsWithoutChangingSettings() {
        var selections = 0
        let button = RouteSelectionMenuButton()
        button.configure(title: "medium", accessibilityLabel: "推理强度", items: [
            RouteSelectionMenuItem(id: "low", title: "low", action: { selections += 1 }),
            .separator,
            RouteSelectionMenuItem(id: "medium", title: "medium", isSelected: true, action: { selections += 1 }),
        ])
        let menu = button.makeMenu()
        XCTAssertEqual(menu.items.map(\.title), ["low", "", "medium"])
        XCTAssertEqual(menu.items[0].state, .off)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].state, .on)
        XCTAssertEqual(menu.items[2].identifier?.rawValue, "medium")
        XCTAssertEqual(button.accessibilityRole(), .popUpButton)
        XCTAssertEqual(button.accessibilityValue() as? String, "medium")
        XCTAssertEqual(selections, 0)
    }

    func testSelectionRunsOnlyAfterMenuTrackingAndCancellationDoesNotWrite() {
        let (window, button) = self.fixture()
        defer { window.contentView = nil; window.close() }
        var values: [String] = []
        button.configure(title: "standard", accessibilityLabel: "服务档位", items: [
            RouteSelectionMenuItem(id: "priority", title: "fast") {
                XCTAssertFalse(RouteSelectionMenuTracking.isActive)
                values.append("priority")
            },
        ])
        button.menuPresenter = { _, origin, view in
            XCTAssertTrue(RouteSelectionMenuTracking.isActive)
            if view.isFlipped {
                XCTAssertGreaterThan(origin.y, view.bounds.maxY, "菜单应从控件下方展开")
            } else {
                XCTAssertLessThan(origin.y, view.bounds.minY, "菜单应从控件下方展开")
            }
        }
        button.performClick(nil)
        XCTAssertEqual(values, [])
        XCTAssertFalse(RouteSelectionMenuTracking.isActive)
        button.menuPresenter = { menu, _, _ in
            let item = menu.items[0]
            XCTAssertTrue(RouteSelectionMenuTracking.isActive)
            XCTAssertTrue(NSApplication.shared.sendAction(item.action!, to: item.target, from: item))
            XCTAssertEqual(values, [], "选择动作应在菜单退出跟踪后执行")
        }
        button.performClick(nil)
        XCTAssertEqual(values, ["priority"])
        XCTAssertFalse(RouteSelectionMenuTracking.isActive)
        XCTAssertFalse(window.isVisible)
    }

    func testHoverOpensOnceAndRequiresReentryAfterCancellation() async throws {
        let (window, button) = self.fixture()
        defer { window.contentView = nil; window.close() }
        var presentations = 0
        var selections = 0
        button.configure(title: "medium", accessibilityLabel: "推理强度", items: [
            RouteSelectionMenuItem(id: "medium", title: "medium", action: { selections += 1 }),
        ])
        button.menuPresenter = { _, _, _ in presentations += 1 }
        button.setHovered(true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(presentations, 1)
        button.setHovered(true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(presentations, 1)
        button.setHovered(false)
        button.setHovered(true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(presentations, 2)
        XCTAssertEqual(selections, 0)
    }

    func testLeavingDisablingOrRemovingControlCancelsPendingHover() async throws {
        let (window, button) = self.fixture()
        defer { window.contentView = nil; window.close() }
        var presentations = 0
        let items = [RouteSelectionMenuItem(id: "model", title: "gpt-6.1-sol")]
        button.configure(title: "gpt-6.1-sol", accessibilityLabel: "模型", items: items)
        button.menuPresenter = { _, _, _ in presentations += 1 }
        button.setHovered(true)
        button.setHovered(false)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(presentations, 0)
        button.setHovered(true)
        button.configure(title: "gpt-6.1-sol", accessibilityLabel: "模型", items: items, isEnabled: false)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(presentations, 0)
        button.setHovered(true)
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(presentations, 0)
        button.configure(title: "gpt-6.1-sol", accessibilityLabel: "模型", items: items)
        button.setHovered(true)
        button.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(presentations, 0)
        XCTAssertFalse(RouteSelectionMenuTracking.isActive)
    }

    func testHoverMenuAllowsEnteringMenuAndBriefExcursionsThenDismissesOnExit() async throws {
        let (window, button) = self.fixture()
        defer { window.contentView = nil; window.close() }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let menu = TrackingMenu()
        menu.screenFrame = NSRect(x: buttonFrame.minX, y: buttonFrame.minY - 123, width: 180, height: 120)
        let menuPoint = NSPoint(x: menu.screenFrame.midX, y: menu.screenFrame.midY)
        var pointer = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        button.pointerLocation = { pointer }
        button.menuFactory = { menu }
        button.configure(title: "medium", accessibilityLabel: "推理强度", items: [RouteSelectionMenuItem(id: "medium", title: "medium")])
        var presentations = 0
        button.menuPresenter = { _, _, _ in
            presentations += 1
            XCTAssertTrue(button.isMonitoringHoverDismissal)
            self.runTrackingLoop(for: 0.08)
            pointer = NSPoint(x: buttonFrame.midX, y: buttonFrame.minY - 1.5)
            self.runTrackingLoop(for: 0.23)
            XCTAssertEqual(menu.cancellations, 0, "按钮与菜单间隙不能触发关闭")
            button.setHovered(false)
            pointer = menuPoint
            self.runTrackingLoop(for: 0.23)
            XCTAssertEqual(menu.cancellations, 0, "指针进入菜单后应保持展开")
            pointer = NSPoint(x: menu.screenFrame.maxX + 40, y: menu.screenFrame.midY)
            self.runTrackingLoop(for: 0.08)
            pointer = menuPoint
            self.runTrackingLoop(for: 0.23)
            XCTAssertEqual(menu.cancellations, 0, "短暂移出后返回应取消关闭倒计时")
            pointer = NSPoint(x: menu.screenFrame.maxX + 40, y: menu.screenFrame.midY)
            self.runTrackingLoop(for: 0.28)
            XCTAssertEqual(menu.cancellations, 1, "事件跟踪循环内离开两处区域后应关闭")
            XCTAssertFalse(button.isMonitoringHoverDismissal)
        }
        button.setHovered(true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(presentations, 1)
        XCTAssertFalse(RouteSelectionMenuTracking.isActive)
        button.menuPresenter = { _, _, _ in presentations += 1 }
        pointer = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        button.setHovered(true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(presentations, 2, "移开关闭后重新进入应再次展开")
        button.setHovered(true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(presentations, 2, "关闭时指针仍在按钮上不能立即重新展开")
    }

    func testClickMenuDoesNotAutoDismissAndDisablingStopsHoverTracking() async throws {
        let (window, button) = self.fixture()
        defer { window.contentView = nil; window.close() }
        let menu = TrackingMenu()
        menu.screenFrame = NSRect(x: 10, y: 50, width: 150, height: 100)
        button.menuFactory = { menu }
        button.pointerLocation = { NSPoint(x: -500, y: -500) }
        let items = [RouteSelectionMenuItem(id: "model", title: "gpt-6.1-sol")]
        button.configure(title: "gpt-6.1-sol", accessibilityLabel: "模型", items: items)
        button.menuPresenter = { _, _, _ in
            XCTAssertFalse(button.isMonitoringHoverDismissal)
            self.runTrackingLoop(for: 0.28)
            XCTAssertEqual(menu.cancellations, 0, "点击或键盘弹出的菜单保持原生交互")
        }
        button.performClick(nil)
        button.menuPresenter = { _, _, _ in
            XCTAssertTrue(button.isMonitoringHoverDismissal)
            button.configure(title: "gpt-6.1-sol", accessibilityLabel: "模型", items: items, isEnabled: false)
            XCTAssertEqual(menu.cancellations, 1)
            XCTAssertFalse(button.isMonitoringHoverDismissal)
            self.runTrackingLoop(for: 0.24)
            XCTAssertEqual(menu.cancellations, 1, "禁用后不应残留轮询计时器")
        }
        button.setHovered(true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertFalse(RouteSelectionMenuTracking.isActive)
        XCTAssertFalse(button.isMonitoringHoverDismissal)
    }

    func testHoverDismissalUsesScreenFramesAndWaitsForMenuLayout() {
        let button = NSRect(x: -900, y: 300, width: 140, height: 24)
        // 菜单在屏幕边缘可能展开到按钮上方，不能假设固定向下。
        let menu = NSRect(x: -920, y: 327, width: 200, height: 240)
        var dismissal = RouteSelectionHoverDismissal()
        let inside = NSPoint(x: menu.midX, y: menu.midY)
        XCTAssertFalse(dismissal.shouldDismiss(pointer: inside, buttonFrame: button, menuFrame: nil, now: 0))
        XCTAssertFalse(dismissal.shouldDismiss(pointer: inside, buttonFrame: button, menuFrame: menu, now: 1))
        let outside = NSPoint(x: -600, y: 280)
        XCTAssertFalse(dismissal.shouldDismiss(pointer: outside, buttonFrame: button, menuFrame: menu, now: 2))
        XCTAssertFalse(dismissal.shouldDismiss(pointer: outside, buttonFrame: button, menuFrame: menu, now: 2.17))
        XCTAssertTrue(dismissal.shouldDismiss(pointer: outside, buttonFrame: button, menuFrame: menu, now: 2.19))
    }

    func testMenuGeometryPlacesMenuBelowButtonAndClampsAtScreenEdges() {
        let screen = NSRect(x: 0, y: 24, width: 1440, height: 876)
        let size = NSSize(width: 180, height: 240)
        let below = RouteSelectionMenuGeometry.estimatedFrame(menuSize: size, popUpOrigin: NSPoint(x: 200, y: 600),
                                                             screenVisibleFrame: screen, isRightToLeft: false)
        XCTAssertEqual(below, NSRect(x: 200, y: 360, width: 180, height: 240))
        let nearBottomRight = RouteSelectionMenuGeometry.estimatedFrame(menuSize: size, popUpOrigin: NSPoint(x: 1400, y: 70),
                                                                       screenVisibleFrame: screen, isRightToLeft: false)
        XCTAssertEqual(nearBottomRight, NSRect(x: 1260, y: 24, width: 180, height: 240))
        XCTAssertGreaterThan(nearBottomRight.maxY, 70, "屏幕下边缘应把菜单上移到可见范围")
    }

    func testMenuGeometrySupportsNegativeScreenCoordinatesAndRightToLeft() {
        let screen = NSRect(x: -1600, y: -180, width: 1600, height: 1000)
        let size = NSSize(width: 180, height: 240)
        let frame = RouteSelectionMenuGeometry.estimatedFrame(menuSize: size, popUpOrigin: NSPoint(x: -900, y: 500),
                                                             screenVisibleFrame: screen, isRightToLeft: true)
        XCTAssertEqual(frame, NSRect(x: -1080, y: 260, width: 180, height: 240))
        let edge = RouteSelectionMenuGeometry.estimatedFrame(menuSize: size, popUpOrigin: NSPoint(x: -1550, y: -100),
                                                            screenVisibleFrame: screen, isRightToLeft: true)
        XCTAssertEqual(edge, NSRect(x: -1600, y: -180, width: 180, height: 240))
    }

    func testMenuGeometryClipsOversizedMenuToItsOwnScreen() {
        let screen = NSRect(x: -800, y: 100, width: 800, height: 600)
        let frame = RouteSelectionMenuGeometry.estimatedFrame(menuSize: NSSize(width: 1000, height: 1600),
                                                             popUpOrigin: NSPoint(x: -600, y: 500),
                                                             screenVisibleFrame: screen, isRightToLeft: false)
        XCTAssertEqual(frame, screen)
    }

    func testHoverMenuDismissesWhenAccessibilityFramesStayEmpty() async throws {
        let (window, button) = self.fixture()
        defer { window.contentView = nil; window.close() }
        let menu = TrackingMenu()
        button.menuFactory = { menu }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        var pointer = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        button.pointerLocation = { pointer }
        button.configure(title: "medium", accessibilityLabel: "推理强度", items: [RouteSelectionMenuItem(id: "medium", title: "medium")])
        button.menuPresenter = { menu, _, _ in
            XCTAssertTrue(menu.accessibilityFrame().isEmpty)
            XCTAssertTrue(menu.items.allSatisfy { $0.accessibilityFrame().isEmpty })
            self.runTrackingLoop(for: 0.25)
            XCTAssertEqual((menu as? TrackingMenu)?.cancellations, 0, "按钮内保持展开")
            pointer = NSPoint(x: buttonFrame.maxX + 10_000, y: buttonFrame.maxY + 10_000)
            self.runTrackingLoop(for: 0.3)
            XCTAssertEqual((menu as? TrackingMenu)?.cancellations, 1, "AX 范围始终为空时仍能移开关闭")
            XCTAssertFalse(button.isMonitoringHoverDismissal)
        }
        button.setHovered(true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(menu.cancellations, 1)
        XCTAssertFalse(RouteSelectionMenuTracking.isActive)
    }

    func testSettingsFontSizeKeepsCompactControlUsable() {
        let button = RouteSelectionMenuButton()
        button.configure(title: "自动", accessibilityLabel: "外观", items: [], fontSize: 12)
        XCTAssertEqual(button.font?.pointSize, 12)
        XCTAssertEqual(button.intrinsicContentSize.height, 26)
    }

    func testCompactControlRendersOffscreenWithConstrainedWidth() throws {
        let (window, button) = self.fixture()
        defer { window.contentView = nil; window.close() }
        button.configure(title: "gpt-6.1-sol-very-long-model", accessibilityLabel: "模型", items: [])
        button.frame = NSRect(x: 10, y: 10, width: 116, height: 24)
        XCTAssertEqual(button.font?.pointSize, 10)
        XCTAssertEqual(button.intrinsicContentSize.height, 24)
        XCTAssertGreaterThan(button.intrinsicContentSize.width, button.frame.width)
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-route-selection-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            button.displayIfNeeded()
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 100)
            try png.write(to: output.appendingPathComponent("route-selection-\(name).png"))
        }
        XCTAssertFalse(window.isVisible)
    }

    private func fixture() -> (NSWindow, RouteSelectionMenuButton) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 44), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = RouteSelectionMenuButton(frame: NSRect(x: 10, y: 10, width: 140, height: 24))
        window.contentView?.addSubview(button)
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        button.pointerLocation = { NSPoint(x: buttonFrame.midX, y: buttonFrame.midY) }
        return (window, button)
    }

    private func runTrackingLoop(for duration: TimeInterval) {
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            RunLoop.main.run(mode: .eventTracking, before: end)
        }
    }
}

@MainActor
private final class TrackingMenu: NSMenu {
    var screenFrame = NSRect.zero
    var cancellations = 0

    override func accessibilityFrame() -> NSRect { MainActor.assumeIsolated { self.screenFrame } }
    override func cancelTracking() { MainActor.assumeIsolated { self.cancellations += 1 } }
}
