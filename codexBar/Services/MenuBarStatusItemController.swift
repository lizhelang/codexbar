import AppKit
import Carbon
import Combine
import SwiftUI

extension Notification.Name {
    static let codexbarRequestCloseStatusItemMenu = Notification.Name("lzl.codexbar.status-item-menu.close")
    static let codexbarStatusItemMeasuredHeightDidChange = Notification.Name("lzl.codexbar.status-item-menu.height-changed")
    static let codexbarRequestStatusItemLayoutRefresh = Notification.Name("lzl.codexbar.status-item-menu.layout-refresh")
}

private enum MenuBarGlobalShortcut {
    static let keyCode = UInt32(kVK_ANSI_B)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let signature: OSType = 0x43444252
    static let identifier: UInt32 = 1
}

enum MenuBarPopoverSizing {
    static let defaultHeight: CGFloat = 520
    static let minimumHeight: CGFloat = 320
    static let maximumHeight: CGFloat = 640
    static let verticalMargin: CGFloat = 12
    static let topContentInset: CGFloat = 10
    static let bottomContentInset: CGFloat = 12

    static func clampedHeight(desiredHeight: CGFloat, availableHeight: CGFloat?) -> CGFloat {
        let boundedAvailableHeight = max(self.minimumHeight, availableHeight ?? self.maximumHeight)
        let maxHeight = min(self.maximumHeight, boundedAvailableHeight)
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

@MainActor
final class MenuBarStatusItemController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarStatusItemController()

    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var latestMeasuredContentHeight: CGFloat?
    private var cancellables: Set<AnyCancellable> = []
    private lazy var hotKeyController = StatusItemHotKeyController { [weak self] in
        self?.togglePopoverFromKeyboardShortcut()
    }

    private override init() {
        super.init()
        self.popover.behavior = .transient
        self.popover.delegate = self
    }

    func start() {
        guard self.statusItem == nil else {
            self.statusItem?.isVisible = true
            self.updateAppearance()
            return
        }

        MenuBarStatusItemIdentity.repairVisibilityIfNeeded()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = MenuBarStatusItemIdentity.statusItemAutosaveName
        item.isVisible = true
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
        self.popover.contentViewController = NSHostingController(
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
        self.popover.performClose(nil)
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        self.statusItem = nil
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
                guard self.popover.isShown else { return }
                self.refreshPopoverSize(
                    desiredContentHeight: self.latestMeasuredContentHeight,
                    availableHeight: self.availablePopoverHeightBelowStatusItem()
                )
            }
            .store(in: &self.cancellables)

        NotificationCenter.default.publisher(for: .codexbarRequestStatusItemLayoutRefresh)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.popover.isShown else { return }
                self.schedulePopoverSizeRefresh(
                    availableHeight: self.availablePopoverHeightBelowStatusItem(),
                    remainingAttempts: 2
                )
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
            updateAvailable: UpdateCoordinator.shared.pendingAvailability != nil
        )

        button.image = NSImage(
            systemSymbolName: presentation.iconName,
            accessibilityDescription: MenuBarStatusItemIdentity.accessibilityLabel
        )
        button.contentTintColor = presentation.foregroundColor

        if presentation.title.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            button.attributedTitle = NSAttributedString(
                string: " " + presentation.title,
                attributes: [
                    .font: presentation.font,
                    .foregroundColor: presentation.foregroundColor,
                ]
            )
        }
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        if self.popover.isShown {
            self.closePopover(sender)
            return
        }
        self.showPopover(trigger: "button")
    }

    private func togglePopoverFromKeyboardShortcut() {
        if self.statusItem == nil {
            self.start()
        }
        if self.popover.isShown {
            self.closePopover()
            return
        }
        self.showPopover(trigger: "keyboard_shortcut")
    }

    private func showPopover(trigger: String) {
        guard let button = self.statusItem?.button else { return }

        self.updateAppearance()
        let availableHeight = self.availablePopoverHeightBelowStatusItem()
        self.popover.contentSize = MenuBarPopoverSizing.initialSize(availableHeight: availableHeight)
        NSApp.activate(ignoringOtherApps: true)
        self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        self.popover.contentViewController?.view.window?.makeKey()
        self.schedulePopoverSizeRefresh(availableHeight: availableHeight)
        AppLifecycleDiagnostics.shared.recordEvent(
            type: "status_item_menu_opened",
            fields: [
                "pid": getpid(),
                "trigger": trigger,
            ]
        )
    }

    private func closePopover(_ sender: AnyObject? = nil) {
        guard self.popover.isShown else { return }
        self.popover.performClose(sender)
    }

    private func schedulePopoverSizeRefresh(
        availableHeight: CGFloat?,
        remainingAttempts: Int = 3
    ) {
        guard remainingAttempts > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.refreshPopoverSize(
                desiredContentHeight: self.latestMeasuredContentHeight,
                availableHeight: availableHeight ?? self.availablePopoverHeightBelowStatusItem()
            )
            self.schedulePopoverSizeRefresh(
                availableHeight: availableHeight,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private func refreshPopoverSize(
        desiredContentHeight: CGFloat?,
        availableHeight: CGFloat?
    ) {
        guard let view = self.popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let contentHeight = desiredContentHeight ?? view.fittingSize.height
        self.popover.contentSize = NSSize(
            width: MenuBarStatusItemIdentity.popoverContentWidth,
            height: MenuBarPopoverSizing.clampedHeight(
                desiredHeight: contentHeight,
                availableHeight: availableHeight
            )
        )
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

    func popoverDidClose(_ notification: Notification) {
        self.statusItem?.button?.highlight(false)
    }
}
