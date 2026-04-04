import AppKit
import ApplicationServices
import Foundation

let authPrefix = "https://auth.openai.com/oauth/authorize?"
let copyButtonDescriptions = ["Copy Login Link", "Copy Link"]
let openButtonDescriptions = ["Open Browser"]
let windowTitle = "OpenAI OAuth"
let bundleID = "lzhl.codexAppBar"
let clipboardSentinel = "__CODEXBAR_AUTH_URL_PENDING__"

func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func buttonDescription(_ element: AXUIElement) -> String {
    attr(element, kAXDescriptionAttribute) ?? ""
}

func buttonOriginX(_ element: AXUIElement) -> CGFloat {
    guard let position: AXValue = attr(element, kAXPositionAttribute) else {
        return -.greatestFiniteMagnitude
    }
    var point = CGPoint.zero
    AXValueGetValue(position, .cgPoint, &point)
    return point.x
}

func collectButtons(in element: AXUIElement) -> [AXUIElement] {
    var buttons: [AXUIElement] = []

    if let role: String = attr(element, kAXRoleAttribute),
       role == kAXButtonRole as String {
        buttons.append(element)
    }

    let children: [AXUIElement] = attr(element, kAXChildrenAttribute) ?? []
    for child in children {
        buttons.append(contentsOf: collectButtons(in: child))
    }

    return buttons
}

func readClipboard() -> String? {
    NSPasteboard.general.string(forType: .string)
}

func writeClipboard(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
}

let pasteboard = NSPasteboard.general
let initialChangeCount = pasteboard.changeCount
writeClipboard(clipboardSentinel)

let deadline = Date().addingTimeInterval(10)

while Date() < deadline {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    if let app = apps.first {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let windows: [AXUIElement] = attr(appElement, kAXWindowsAttribute),
           let window = windows.first(where: { (attr($0, kAXTitleAttribute) as String?) == windowTitle }) {
            let buttons = collectButtons(in: window)
            let openButton = buttons.first(where: { openButtonDescriptions.contains(buttonDescription($0)) })
            let copyCandidates = buttons.filter { copyButtonDescriptions.contains(buttonDescription($0)) }

            guard let copyButton = copyCandidates.max(by: { buttonOriginX($0) < buttonOriginX($1) }) else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }

            if let openButton, buttonOriginX(copyButton) <= buttonOriginX(openButton) {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }

            let result = AXUIElementPerformAction(copyButton, kAXPressAction as CFString)
            guard result == .success else {
                fputs("Failed to press Copy Login Link button.\n", stderr)
                exit(1)
            }

            let copyDeadline = Date().addingTimeInterval(5)
            while Date() < copyDeadline {
                if pasteboard.changeCount != initialChangeCount,
                   let candidate = readClipboard(),
                   candidate.hasPrefix(authPrefix) {
                    print(candidate)
                    exit(0)
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    Thread.sleep(forTimeInterval: 0.2)
}

fputs("Timed out waiting for Copy Login Link clipboard value.\n", stderr)
exit(1)
