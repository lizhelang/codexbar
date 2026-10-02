import AppKit
import SwiftUI

@MainActor
struct RouteSelectionMenuItem {
    let id: String
    let title: String
    var isSelected = false
    var isSeparator = false
    var action: () -> Void = {}

    static var separator: Self {
        Self(id: UUID().uuidString, title: "", isSeparator: true)
    }
}

/// 原生菜单会拥有自己的窗口；跟踪期间由它处理外部点击及 Escape。
@MainActor
enum RouteSelectionMenuTracking {
    private static var depth = 0
    static var isActive: Bool { self.depth > 0 }

    static func begin() { self.depth += 1 }
    static func end() { self.depth = max(0, self.depth - 1) }
}

/// 按钮和原生菜单之间留有间隙，短暂离开不能中断移入菜单的动作。
struct RouteSelectionHoverDismissal {
    private var outsideSince: TimeInterval?

    mutating func shouldDismiss(pointer: NSPoint, buttonFrame: NSRect, menuFrame: NSRect?, now: TimeInterval) -> Bool {
        guard let menuFrame, !menuFrame.isEmpty else {
            self.outsideSince = nil
            return false
        }
        if buttonFrame.insetBy(dx: -4, dy: -4).contains(pointer) ||
            menuFrame.insetBy(dx: -4, dy: -4).contains(pointer) {
            self.outsideSince = nil
            return false
        }
        guard let outsideSince else {
            self.outsideSince = now
            return false
        }
        return now - outsideSince >= 0.18
    }
}

/// AX 尚未提供位置时，按 popUp(positioning:nil) 的公开定位规则估算菜单范围。
struct RouteSelectionMenuGeometry {
    static func estimatedFrame(menuSize: NSSize, popUpOrigin: NSPoint, screenVisibleFrame: NSRect?, isRightToLeft: Bool) -> NSRect {
        var size = NSSize(width: max(1, menuSize.width), height: max(1, menuSize.height))
        if let screen = screenVisibleFrame, !screen.isEmpty {
            size.width = min(size.width, screen.width)
            size.height = min(size.height, screen.height)
        }
        var origin = NSPoint(x: isRightToLeft ? popUpOrigin.x - size.width : popUpOrigin.x,
                             y: popUpOrigin.y - size.height)
        if let screen = screenVisibleFrame, !screen.isEmpty {
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        }
        return NSRect(origin: origin, size: size)
    }
}

@MainActor
struct RouteSelectionMenu: NSViewRepresentable {
    let title: String
    let accessibilityLabel: String
    let items: [RouteSelectionMenuItem]
    var fontSize: Double = 10
    var compact: Bool = false
    var fillsAvailableWidth: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> RouteSelectionMenuButton {
        let button = RouteSelectionMenuButton()
        self.updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: RouteSelectionMenuButton, context: Context) {
        button.configure(
            title: self.title,
            accessibilityLabel: self.accessibilityLabel,
            items: self.items,
            fontSize: self.fontSize,
            fontScale: ApplicationPreferencesStore.shared.preferences.fontScale,
            isEnabled: self.isEnabled,
            compact: self.compact
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RouteSelectionMenuButton, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        let proposedWidth = max(36, proposal.width ?? intrinsic.width)
        let width = self.fillsAvailableWidth && proposedWidth.isFinite
            ? proposedWidth : min(intrinsic.width, proposedWidth)
        return CGSize(width: width, height: intrinsic.height)
    }

    static func dismantleNSView(_ nsView: RouteSelectionMenuButton, coordinator: ()) {
        nsView.cancelPendingPresentation()
    }
}

@MainActor
final class RouteSelectionMenuButton: NSButton {
    private var items: [RouteSelectionMenuItem] = []
    private var menuTrackingArea: NSTrackingArea?
    private var pendingHover: Task<Void, Never>?
    private var isHovered = false
    private var hoverPresentationConsumed = false
    private var isPresentingMenu = false
    private var activeMenu: NSMenu?
    private var activeMenuScreenOrigin: NSPoint?
    private var pendingSelection: (() -> Void)?
    private var fontScale: CGFloat = 1
    private var fontSize: CGFloat = 10
    private var textInset: CGFloat = 8
    private var arrowWidth: CGFloat = 19
    private var hoverDismissalTimer: Timer?
    private var hoverDismissal = RouteSelectionHoverDismissal()

    /// 测试替身只截获弹出过程，不创建可见窗口或进入菜单模态循环。
    var menuPresenter: ((NSMenu, NSPoint, NSView) -> Void)?
    var menuFactory: (() -> NSMenu)?
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var isMonitoringHoverDismissal: Bool { self.hoverDismissalTimer?.isValid == true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setButtonType(.momentaryChange)
        self.isBordered = false
        self.focusRingType = .none
        self.target = self
        self.action = #selector(self.openFromClick(_:))
        self.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        self.setAccessibilityRole(.popUpButton)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, accessibilityLabel: String, items: [RouteSelectionMenuItem], fontSize: Double = 10, fontScale: Double = 1, isEnabled: Bool = true, compact: Bool = false) {
        self.title = title
        self.items = items
        self.fontScale = CGFloat(fontScale)
        self.fontSize = CGFloat(fontSize)
        self.textInset = compact ? 6 : 8
        self.arrowWidth = compact ? 16 : 19
        self.font = .systemFont(ofSize: self.fontSize * self.fontScale, weight: .medium)
        self.isEnabled = isEnabled
        self.setAccessibilityLabel(accessibilityLabel)
        self.setAccessibilityValue(title)
        if !isEnabled { self.cancelPendingPresentation() }
        self.invalidateIntrinsicContentSize()
        self.needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let textWidth = (self.title as NSString).size(withAttributes: [.font: self.font ?? NSFont.systemFont(ofSize: 10)]).width
        return NSSize(width: ceil(textWidth) + self.textInset * 2 + self.arrowWidth, height: max(24, ceil((self.fontSize + 14) * self.fontScale)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let emphasized = self.isEnabled && (self.isHovered || self.isPresentingMenu || self.isHighlighted)
        NSColor(MenuSurface.raised).withAlphaComponent(emphasized ? 0.95 : 0.55).setFill()
        outline.fill()
        (emphasized ? NSColor(MenuSurface.accent).withAlphaComponent(0.7) : NSColor.labelColor.withAlphaComponent(0.22)).setStroke()
        outline.lineWidth = 0.75
        outline.stroke()

        let arrowWidth = self.arrowWidth
        let dividerX = self.bounds.maxX - arrowWidth
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: dividerX, y: rect.minY))
        divider.line(to: NSPoint(x: dividerX, y: rect.maxY))
        NSColor.labelColor.withAlphaComponent(0.16).setStroke()
        divider.lineWidth = 0.75
        divider.stroke()

        let color = self.isEnabled ? NSColor(MenuSurface.accent) : NSColor.disabledControlTextColor
        let font = self.font ?? NSFont.systemFont(ofSize: 10, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let textHeight = font.ascender - font.descender
        let textRect = NSRect(x: self.textInset, y: (self.bounds.height - textHeight) / 2 - 0.5, width: max(0, dividerX - self.textInset * 2), height: textHeight + 1)
        (self.title as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])

        let arrow = NSBezierPath()
        let center = NSPoint(x: dividerX + arrowWidth / 2, y: self.bounds.midY)
        let down: CGFloat = self.isFlipped ? 1 : -1
        arrow.move(to: NSPoint(x: center.x - 3, y: center.y - down * 1.5))
        arrow.line(to: NSPoint(x: center.x, y: center.y + down * 1.5))
        arrow.line(to: NSPoint(x: center.x + 3, y: center.y - down * 1.5))
        arrow.lineWidth = 1.1
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        color.setStroke()
        arrow.stroke()
    }

    override func updateTrackingAreas() {
        if let menuTrackingArea { self.removeTrackingArea(menuTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        self.addTrackingArea(area)
        self.menuTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { self.setHovered(true) }
    override func mouseExited(with event: NSEvent) { self.setHovered(false) }

    func setHovered(_ hovered: Bool) {
        self.isHovered = hovered
        self.needsDisplay = true
        self.pendingHover?.cancel()
        self.pendingHover = nil
        if !hovered {
            if !self.isPresentingMenu { self.hoverPresentationConsumed = false }
            return
        }
        guard self.isEnabled, !self.hoverPresentationConsumed, !self.isPresentingMenu else { return }
        self.pendingHover = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard let self, self.isHovered, !Task.isCancelled else { return }
            self.presentMenu(openedByHover: true)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil { self.cancelPendingPresentation() }
    }

    func cancelPendingPresentation() {
        self.pendingHover?.cancel()
        self.pendingHover = nil
        self.isHovered = false
        self.hoverPresentationConsumed = false
        self.stopHoverDismissal()
        self.activeMenu?.cancelTracking()
    }

    func makeMenu() -> NSMenu {
        let menu = self.menuFactory?() ?? NSMenu()
        menu.autoenablesItems = false
        for item in self.items {
            if item.isSeparator { menu.addItem(.separator()); continue }
            let menuItem = NSMenuItem(title: item.title, action: #selector(self.queueSelection(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.identifier = NSUserInterfaceItemIdentifier(item.id)
            menuItem.state = item.isSelected ? .on : .off
            menuItem.representedObject = RouteSelectionMenuAction(action: item.action)
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func openFromClick(_ sender: Any?) { self.presentMenu(openedByHover: false) }

    private func presentMenu(openedByHover: Bool) {
        guard self.isEnabled, self.window != nil, !self.isPresentingMenu, !self.items.isEmpty else { return }
        guard self.menuPresenter != nil || self.window?.isVisible == true else { return }
        self.pendingHover?.cancel()
        self.pendingHover = nil
        self.hoverPresentationConsumed = true
        self.pendingSelection = nil
        self.trackMenu(self.makeMenu(), openedByHover: openedByHover)
        // NSAlert 等后续交互必须在原生菜单结束跟踪之后才发生。
        let selection = self.pendingSelection
        self.pendingSelection = nil
        selection?()
    }

    private func trackMenu(_ menu: NSMenu, openedByHover: Bool) {
        self.isPresentingMenu = true
        self.activeMenu = menu
        self.needsDisplay = true
        RouteSelectionMenuTracking.begin()
        defer {
            self.stopHoverDismissal()
            RouteSelectionMenuTracking.end()
            self.activeMenu = nil
            self.activeMenuScreenOrigin = nil
            self.isPresentingMenu = false
            // 原生菜单跟踪期间可能吞掉 entered/exited；以实际指针位置恢复状态。
            self.isHovered = self.buttonScreenFrame?.contains(self.pointerLocation()) == true
            self.hoverPresentationConsumed = self.isHovered
            self.needsDisplay = true
        }
        let origin = NSPoint(x: self.bounds.minX, y: self.isFlipped ? self.bounds.maxY + 3 : self.bounds.minY - 3)
        self.activeMenuScreenOrigin = self.window?.convertPoint(toScreen: self.convert(origin, to: nil))
        if openedByHover { self.startHoverDismissal() }
        if let menuPresenter { menuPresenter(menu, origin, self) }
        else { menu.popUp(positioning: nil, at: origin, in: self) }
    }

    private var buttonScreenFrame: NSRect? {
        self.window.map { $0.convertToScreen(self.convert(self.bounds, to: nil)) }
    }

    private func menuScreenFrame(_ menu: NSMenu) -> NSRect? {
        let frame = menu.accessibilityFrame()
        if !frame.isEmpty { return frame }
        // 菜单刚展开时整个菜单的 AX frame 可能还未就绪，条目已有屏幕坐标。
        let itemFrames = menu.items.filter { !$0.isHidden }.map { $0.accessibilityFrame() }.filter { !$0.isEmpty }
        if let itemFrame = itemFrames.reduce(nil as NSRect?, { result, frame in result.map { $0.union(frame) } ?? frame }) {
            return itemFrame
        }
        guard let origin = self.activeMenuScreenOrigin else { return nil }
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? self.window?.screen
        // size 是 NSMenu 的公开布局尺寸；零尺寸只会出现在尚未完成布局时。
        let measuredSize = menu.size
        let size = NSSize(width: measuredSize.width > 0 ? measuredSize.width : max(self.bounds.width, 120),
                          height: measuredSize.height > 0 ? measuredSize.height : CGFloat(menu.items.filter { !$0.isHidden }.count) * 22 + 12)
        return RouteSelectionMenuGeometry.estimatedFrame(menuSize: size, popUpOrigin: origin,
                                                        screenVisibleFrame: screen?.visibleFrame,
                                                        isRightToLeft: self.userInterfaceLayoutDirection == .rightToLeft)
    }

    private func startHoverDismissal() {
        self.stopHoverDismissal()
        let timer = Timer(timeInterval: 0.04, target: self, selector: #selector(self.checkHoverDismissal), userInfo: nil, repeats: true)
        timer.tolerance = 0.01
        self.hoverDismissalTimer = timer
        // popUp 使用嵌套事件跟踪循环，默认模式的计时器在菜单打开时不会执行。
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHoverDismissal() {
        self.hoverDismissalTimer?.invalidate()
        self.hoverDismissalTimer = nil
        self.hoverDismissal = RouteSelectionHoverDismissal()
    }

    @objc private func checkHoverDismissal() {
        guard let menu = self.activeMenu, let buttonFrame = self.buttonScreenFrame else {
            self.stopHoverDismissal()
            return
        }
        if self.hoverDismissal.shouldDismiss(pointer: self.pointerLocation(), buttonFrame: buttonFrame,
                                             menuFrame: self.menuScreenFrame(menu), now: ProcessInfo.processInfo.systemUptime) {
            self.stopHoverDismissal()
            menu.cancelTracking()
        }
    }

    @objc private func queueSelection(_ sender: NSMenuItem) {
        guard self.isPresentingMenu,
              let selection = sender.representedObject as? RouteSelectionMenuAction else { return }
        self.pendingSelection = selection.action
    }
}

@MainActor
private final class RouteSelectionMenuAction: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
}
