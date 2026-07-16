import AppKit
import Carbon
import Combine
import SwiftUI

extension Notification.Name {
    static let codexbarRequestCloseStatusItemMenu = Notification.Name("lzl.codexbar.status-item-menu.close")
    static let codexbarStatusItemMeasuredHeightDidChange = Notification.Name("lzl.codexbar.status-item-menu.height-changed")
    static let codexbarStatusItemAvailableContentHeightDidChange = Notification.Name("lzl.codexbar.status-item-menu.available-content-height-changed")
    static let codexbarRequestStatusItemLayoutRefresh = Notification.Name("lzl.codexbar.status-item-menu.layout-refresh")
    static let codexbarStatusItemMenuWillOpen = Notification.Name("lzl.codexbar.status-item-menu.will-open")
    static let codexbarStatusItemMenuDidClose = Notification.Name("lzl.codexbar.status-item-menu.did-close")
}

private enum MenuBarGlobalShortcut {
    static let keyCode = UInt32(kVK_ANSI_B)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let signature: OSType = 0x43444252
    static let identifier: UInt32 = 1
}

enum MenuBarPopoverSizing {
    static let defaultHeight: CGFloat = 520
    static let minimumHeight: CGFloat = 1
    static let maximumHeight: CGFloat = 640
    static let verticalMargin: CGFloat = 12
    static let topContentInset: CGFloat = 10
    static let bottomContentInset: CGFloat = 12

    static func clampedHeight(desiredHeight: CGFloat, availableHeight: CGFloat?) -> CGFloat {
        let maxHeight = max(self.minimumHeight, availableHeight ?? self.maximumHeight)
        return min(max(desiredHeight, self.minimumHeight), maxHeight)
    }

    static func initialSize(availableHeight: CGFloat?) -> NSSize {
        NSSize(
            width: MenuBarStatusItemIdentity.popoverContentWidth,
            height: self.clampedHeight(
                desiredHeight: self.defaultHeight,
                availableHeight: availableHeight
            )
        )
    }

    static func flexibleSectionHeightCap(
        totalContentHeight: CGFloat,
        flexibleSectionHeight: CGFloat,
        availableHeight: CGFloat?
    ) -> CGFloat? {
        guard let availableHeight,
              totalContentHeight > 0,
              flexibleSectionHeight > 0 else {
            return nil
        }

        let fixedHeight = max(totalContentHeight - flexibleSectionHeight, 0)
        return max(availableHeight - fixedHeight, self.minimumHeight)
    }
}

private final class StatusItemHotKeyController {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        self.stop()
    }

    func start() {
        guard self.hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == MenuBarGlobalShortcut.signature,
                      hotKeyID.id == MenuBarGlobalShortcut.identifier else {
                    return noErr
                }

                let controller = Unmanaged<StatusItemHotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                controller.action()
                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &self.eventHandler
        )
        guard installStatus == noErr else { return }

        let hotKeyID = EventHotKeyID(
            signature: MenuBarGlobalShortcut.signature,
            id: MenuBarGlobalShortcut.identifier
        )
        let registerStatus = RegisterEventHotKey(
            MenuBarGlobalShortcut.keyCode,
            MenuBarGlobalShortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &self.hotKeyRef
        )
        if registerStatus != noErr {
            if let eventHandler = self.eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            self.hotKeyRef = nil
        }
    }

    func stop() {
        if let hotKeyRef = self.hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = self.eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

private final class FlatStatusItemMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        self.close()
    }
}

private final class FlatStatusItemMenuContentView: NSView {
    private let visualEffectView = NSVisualEffectView()
    private let hostedContentView: NSView

    init(hostedContentView: NSView) {
        self.hostedContentView = hostedContentView
        super.init(frame: .zero)

        self.wantsLayer = true
        self.layer?.cornerRadius = 18
        self.layer?.masksToBounds = true
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor

        self.visualEffectView.material = .popover
        self.visualEffectView.blendingMode = .behindWindow
        self.visualEffectView.state = .active

        self.addSubview(self.visualEffectView)
        self.addSubview(hostedContentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        self.visualEffectView.frame = self.bounds
        self.hostedContentView.frame = self.bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
    }
}

@MainActor
final class MenuBarStatusItemController: NSObject, NSWindowDelegate {
    static let shared = MenuBarStatusItemController()

    private var menuPanel: NSPanel?
    private var menuContentViewController: NSViewController?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var suppressNextStatusItemToggle = false
    private var statusItem: NSStatusItem?
    private var latestMeasuredContentHeight: CGFloat?
    private var hasCompletedInitialPopoverSizing = false
    private var cancellables: Set<AnyCancellable> = []
    private let popoverResizeAnimationDuration: TimeInterval = 0.16
    private lazy var hotKeyController = StatusItemHotKeyController { [weak self] in
        self?.togglePopoverFromKeyboardShortcut()
    }

    private override init() {
        super.init()
    }

    func start() {
        guard self.statusItem == nil else {
            self.applyVisibilityPreference()
            self.updateAppearance()
            return
        }

        let userDefaults = UserDefaults.standard
        MenuBarStatusItemIdentity.repairVisibilityIfNeeded(userDefaults: userDefaults)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = MenuBarStatusItemIdentity.statusItemAutosaveName
        item.behavior = MenuBarStatusItemIdentity.statusItemBehavior

        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }

        button.target = self
        button.action = #selector(self.togglePopover(_:))
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(MenuBarStatusItemIdentity.accessibilityLabel)
        button.setAccessibilityIdentifier(MenuBarStatusItemIdentity.accessibilityIdentifier)

        self.statusItem = item
        self.applyVisibilityPreference(userDefaults: userDefaults)
        self.menuContentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(TokenStore.shared)
                .environmentObject(OAuthManager.shared)
                .environmentObject(UpdateCoordinator.shared)
        )

        self.bindState()
        self.updateAppearance()
        self.hotKeyController.start()
        AppLifecycleDiagnostics.shared.recordEvent(
            type: "status_item_host_started",
            fields: ["pid": getpid()]
        )
    }

    func stop() {
        self.hotKeyController.stop()
        self.closePopover()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        self.statusItem = nil
        self.menuPanel = nil
        self.menuContentViewController = nil
        self.cancellables.removeAll()
    }

    private func bindState() {
        guard self.cancellables.isEmpty else { return }

        TokenStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleAppearanceRefresh()
            }
            .store(in: &self.cancellables)

        UpdateCoordinator.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleAppearanceRefresh()
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: .codexbarRequestCloseStatusItemMenu)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.closePopover()
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: .codexbarStatusItemMeasuredHeightDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                if let height = notification.userInfo?["height"] as? CGFloat {
                    self.latestMeasuredContentHeight = height
                }
                guard self.isMenuShown else { return }
                self.refreshPopoverSize(
                    desiredContentHeight: self.latestMeasuredContentHeight,
                    availableHeight: self.availablePopoverHeightBelowStatusItem()
                )
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: .codexbarRequestStatusItemLayoutRefresh)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isMenuShown else { return }
                self.schedulePopoverSizeRefresh(
                    desiredContentHeight: nil,
                    availableHeight: self.availablePopoverHeightBelowStatusItem(),
                    remainingAttempts: 6
                )
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyVisibilityPreference()
            }
            .store(in: &self.cancellables)
    }

    private func scheduleAppearanceRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.updateAppearance()
        }
    }

    private func updateAppearance() {
        guard let button = self.statusItem?.button else { return }

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: TokenStore.shared.accounts,
            activeProvider: TokenStore.shared.activeProvider,
            aggregateRoutedAccount: TokenStore.shared.aggregateRoutedAccount,
            usageDisplayMode: TokenStore.shared.config.openAI.usageDisplayMode,
            accountUsageMode: TokenStore.shared.config.openAI.accountUsageMode,
            updateAvailable: UpdateCoordinator.shared.pendingAvailability != nil,
            showsUsageText: TokenStore.shared.config.openAI.showsMenuBarUsageText
        )

        self.statusItem?.length = presentation.layout.statusItemLength
        button.imagePosition = presentation.layout.imagePosition
        button.image = presentation.makeTemplateImage(
            accessibilityDescription: MenuBarStatusItemIdentity.accessibilityLabel
        )
        button.contentTintColor = nil
        button.attributedTitle = presentation.attributedTitle
        button.setAccessibilityValue(presentation.accessibilityValue)
        button.toolTip = presentation.accessibilityValue.isEmpty ? nil : presentation.accessibilityValue
    }

    private func applyVisibilityPreference(userDefaults: UserDefaults = .standard) {
        guard let statusItem = self.statusItem else { return }

        let visible = Self.resolvedVisibilityPreference(userDefaults: userDefaults)
        if visible == false {
            self.closePopover()
        }
        statusItem.isVisible = visible
    }

    nonisolated static func resolvedVisibilityPreference(userDefaults: UserDefaults = .standard) -> Bool {
        MenuBarStatusItemIdentity.resolvedVisibility(domain: userDefaults.dictionaryRepresentation())
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        if self.suppressNextStatusItemToggle {
            self.suppressNextStatusItemToggle = false
            return
        }
        if self.isMenuShown {
            self.closePopover(sender)
            return
        }
        self.showPopover(trigger: "button")
    }

    private func togglePopoverFromKeyboardShortcut() {
        if self.statusItem == nil {
            self.start()
        }
        if self.isMenuShown {
            self.closePopover()
            return
        }
        self.showPopover(trigger: "keyboard_shortcut")
    }

    private func showPopover(trigger: String) {
        guard let button = self.statusItem?.button else { return }

        self.updateAppearance()
        let availableHeight = self.availablePopoverHeightBelowStatusItem()
        let initialSize = MenuBarPopoverSizing.initialSize(availableHeight: availableHeight)
        let panel = self.ensureMenuPanel(contentSize: initialSize)
        self.hasCompletedInitialPopoverSizing = false
        self.setMenuPanelContentSize(initialSize, relativeTo: button, animated: false)
        self.publishAvailableContentHeight(availableHeight)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        button.highlight(true)
        panel.makeKey()
        self.installMenuDismissalMonitors(for: panel)
        self.popoverWillShow(Notification(name: NSPopover.willShowNotification))
        self.schedulePopoverSizeRefresh(
            desiredContentHeight: nil,
            availableHeight: availableHeight
        )
        AppLifecycleDiagnostics.shared.recordEvent(
            type: "status_item_menu_opened",
            fields: [
                "pid": getpid(),
                "trigger": trigger,
            ]
        )
    }

    private func closePopover(_ sender: AnyObject? = nil) {
        guard self.isMenuShown else { return }
        self.menuPanel?.close()
    }

    private var isMenuShown: Bool {
        self.menuPanel?.isVisible == true
    }

    private func schedulePopoverSizeRefresh(
        desiredContentHeight: CGFloat? = nil,
        availableHeight: CGFloat?,
        remainingAttempts: Int = 3
    ) {
        guard remainingAttempts > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isMenuShown else { return }
            self.refreshPopoverSize(
                desiredContentHeight: desiredContentHeight,
                availableHeight: availableHeight ?? self.availablePopoverHeightBelowStatusItem()
            )
            self.schedulePopoverSizeRefresh(
                desiredContentHeight: desiredContentHeight,
                availableHeight: availableHeight,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private func refreshPopoverSize(
        desiredContentHeight: CGFloat?,
        availableHeight: CGFloat?
    ) {
        guard let view = self.menuContentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let contentHeight = desiredContentHeight ?? view.fittingSize.height
        let contentSize = NSSize(
            width: MenuBarStatusItemIdentity.popoverContentWidth,
            height: MenuBarPopoverSizing.clampedHeight(
                desiredHeight: contentHeight,
                availableHeight: availableHeight
            )
        )
        if let panel = self.menuPanel,
           let button = self.statusItem?.button {
            self.setMenuPanelContentSize(
                contentSize,
                relativeTo: button,
                animated: panel.isVisible && self.hasCompletedInitialPopoverSizing
            )
        } else {
            self.setMenuPanelContentSize(contentSize, relativeTo: nil, animated: false)
        }
        self.hasCompletedInitialPopoverSizing = true
        self.publishAvailableContentHeight(availableHeight)
    }

    private func ensureMenuPanel(contentSize: NSSize) -> NSPanel {
        if let menuPanel {
            return menuPanel
        }

        let contentViewController = self.menuContentViewController ?? NSHostingController(
            rootView: MenuBarView()
                .environmentObject(TokenStore.shared)
                .environmentObject(OAuthManager.shared)
                .environmentObject(UpdateCoordinator.shared)
        )
        self.menuContentViewController = contentViewController

        let panel = FlatStatusItemMenuPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = FlatStatusItemMenuContentView(hostedContentView: contentViewController.view)
        self.menuPanel = panel
        return panel
    }

    private func setMenuPanelContentSize(
        _ contentSize: NSSize,
        relativeTo button: NSStatusBarButton?,
        animated: Bool
    ) {
        guard let panel = self.menuPanel else { return }

        guard let button,
              let targetFrame = self.menuPanelFrame(
                forContentSize: contentSize,
                panel: panel,
                relativeTo: button
              ) else {
            panel.setContentSize(contentSize)
            panel.contentView?.needsLayout = true
            return
        }

        let currentFrame = panel.frame
        let hasMeaningfulDelta =
            abs(currentFrame.origin.x - targetFrame.origin.x) > 0.5 ||
            abs(currentFrame.origin.y - targetFrame.origin.y) > 0.5 ||
            abs(currentFrame.width - targetFrame.width) > 0.5 ||
            abs(currentFrame.height - targetFrame.height) > 0.5

        guard animated && hasMeaningfulDelta else {
            panel.setFrame(targetFrame, display: true)
            panel.contentView?.needsLayout = true
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = self.popoverResizeAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
        panel.contentView?.needsLayout = true
    }

    private func positionMenuPanel(_ panel: NSPanel, relativeTo button: NSStatusBarButton) {
        let contentSize = panel.contentView?.bounds.size ?? panel.frame.size
        guard let targetFrame = self.menuPanelFrame(
            forContentSize: contentSize,
            panel: panel,
            relativeTo: button
        ) else { return }
        panel.setFrame(targetFrame, display: true)
    }

    private func menuPanelFrame(
        forContentSize contentSize: NSSize,
        panel: NSPanel,
        relativeTo button: NSStatusBarButton
    ) -> NSRect? {
        guard let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return nil }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = window.convertToScreen(buttonFrameInWindow)
        let visibleFrame = screen.visibleFrame
        let panelFrame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let horizontalMargin: CGFloat = 8
        let verticalGap: CGFloat = 4
        let centeredX = buttonFrameOnScreen.midX - panelFrame.width / 2
        let x = min(
            max(centeredX, visibleFrame.minX + horizontalMargin),
            visibleFrame.maxX - panelFrame.width - horizontalMargin
        )
        let y = max(
            visibleFrame.minY + horizontalMargin,
            buttonFrameOnScreen.minY - panelFrame.height - verticalGap
        )

        return NSRect(x: x, y: y, width: panelFrame.width, height: panelFrame.height)
    }

    private func installMenuDismissalMonitors(for panel: NSPanel) {
        self.removeMenuDismissalMonitors()

        self.localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self, weak panel] event in
            guard let self, let panel else { return event }

            if event.type == .keyDown,
               event.keyCode == UInt16(kVK_Escape) {
                self.closePopover()
                return nil
            }

            if event.window !== panel {
                if self.eventTargetsStatusItemButton(event) {
                    self.suppressNextStatusItemToggle = true
                }
                self.closePopover()
            }
            return event
        }

        self.globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
    }

    private func removeMenuDismissalMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func eventTargetsStatusItemButton(_ event: NSEvent) -> Bool {
        guard let button = self.statusItem?.button,
              event.window === button.window else {
            return false
        }

        let pointInButton = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(pointInButton)
    }

    private func availablePopoverHeightBelowStatusItem() -> CGFloat? {
        guard let button = self.statusItem?.button,
              let window = button.window,
              let screen = window.screen ?? NSScreen.main else {
            return nil
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = window.convertToScreen(buttonFrameInWindow)
        let visibleFrame = screen.visibleFrame
        return max(
            MenuBarPopoverSizing.minimumHeight,
            buttonFrameOnScreen.minY - visibleFrame.minY - MenuBarPopoverSizing.verticalMargin
        )
    }

    func popoverWillShow(_ notification: Notification) {
        NotificationCenter.default.post(name: .codexbarStatusItemMenuWillOpen, object: self)
    }

    func popoverDidClose(_ notification: Notification) {
        self.removeMenuDismissalMonitors()
        self.statusItem?.button?.highlight(false)
        self.hasCompletedInitialPopoverSizing = false
        self.publishAvailableContentHeight(nil)
        NotificationCenter.default.post(name: .codexbarStatusItemMenuDidClose, object: self)
    }

    func windowWillClose(_ notification: Notification) {
        self.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
    }

    private func publishAvailableContentHeight(_ height: CGFloat?) {
        var userInfo: [AnyHashable: Any]?
        if let height {
            userInfo = ["height": height]
        }
        NotificationCenter.default.post(
            name: .codexbarStatusItemAvailableContentHeightDidChange,
            object: self,
            userInfo: userInfo
        )
    }
}
