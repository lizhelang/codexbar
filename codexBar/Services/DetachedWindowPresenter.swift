import AppKit
import SwiftUI

private final class HoverPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct DetachedWindowConfiguration {
    var isResizable = false
    var contentMinSize: CGSize?
    var resetsContentSizeOnReuse = true

    static let standard = Self()

    static let openAISettings = Self(
        isResizable: true,
        contentMinSize: CGSize(width: 760, height: 560),
        resetsContentSizeOnReuse: false
    )
}

final class DetachedWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = DetachedWindowPresenter()

    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(
        id: String,
        title: String,
        size: CGSize,
        configuration: DetachedWindowConfiguration = .standard,
        @ViewBuilder content: () -> Content
    ) {
        let anyView = AnyView(content())

        if let existing = self.windows[id] {
            existing.title = title
            self.applyStandardWindowConfiguration(configuration, to: existing)
            if configuration.resetsContentSizeOnReuse {
                existing.setContentSize(size)
            }
            if let controller = existing.contentViewController as? NSHostingController<AnyView> {
                controller.rootView = anyView
            } else {
                existing.contentViewController = NSHostingController(rootView: anyView)
            }
            NSApp?.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: anyView)
        let window = NSWindow(contentViewController: controller)
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.title = title
        window.level = .floating
        window.isReleasedWhenClosed = false
        self.applyStandardWindowConfiguration(configuration, to: window)
        window.setContentSize(size)
        window.center()
        window.delegate = self

        self.windows[id] = window
        NSApp?.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showHoverPanel<Content: View>(
        id: String,
        size: CGSize,
        origin: CGPoint,
        parent: NSWindow? = nil,
        updateContent: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        let anyView = AnyView(content())

        if let existing = self.windows[id] {
            self.applyHoverPanelGeometry(existing, size: size, origin: origin, parent: parent)
            if updateContent {
                if let controller = existing.contentViewController as? NSHostingController<AnyView> {
                    controller.rootView = anyView
                } else {
                    existing.contentViewController = NSHostingController(rootView: anyView)
                }
            }
            existing.orderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: anyView)
        let window = HoverPanelWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.contentViewController = controller
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.delegate = self

        self.windows[id] = window
        self.applyHoverPanelGeometry(window, size: size, origin: origin, parent: parent)
        window.orderFront(nil)
    }

    static func isHoverPanel(_ window: NSWindow?) -> Bool {
        window is HoverPanelWindow
    }

    func close(id: String) {
        guard let window = self.windows[id] else { return }
        if let parent = window.parent {
            parent.removeChildWindow(window)
        }
        window.close()
        self.windows.removeValue(forKey: id)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = window.identifier?.rawValue else { return }
        self.windows.removeValue(forKey: id)
    }

    private func applyHoverPanelGeometry(
        _ window: NSWindow,
        size: CGSize,
        origin: CGPoint,
        parent: NSWindow?
    ) {
        if window.frame.size != size {
            window.setContentSize(size)
        }
        if window.frame.origin != origin {
            window.setFrameOrigin(origin)
        }
        if let parent, window.parent !== parent {
            if let oldParent = window.parent {
                oldParent.removeChildWindow(window)
            }
            parent.addChildWindow(window, ordered: .above)
        }
    }

    private func applyStandardWindowConfiguration(
        _ configuration: DetachedWindowConfiguration,
        to window: NSWindow
    ) {
        window.styleMask = Self.styleMask(for: configuration)
        window.contentMinSize = configuration.contentMinSize ?? .zero
    }

    private static func styleMask(for configuration: DetachedWindowConfiguration) -> NSWindow.StyleMask {
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if configuration.isResizable {
            styleMask.insert(.resizable)
        }
        return styleMask
    }
}
