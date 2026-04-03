import AppKit
import ApplicationServices
import Foundation

func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func findAuthURL(in element: AXUIElement) -> String? {
    if let value: String = attr(element, kAXValueAttribute),
       value.hasPrefix("https://auth.openai.com/oauth/authorize?") {
        return value
    }

    if let children: [AXUIElement] = attr(element, kAXChildrenAttribute) {
        for child in children {
            if let result = findAuthURL(in: child) {
                return result
            }
        }
    }

    return nil
}

let timeoutSeconds = 10.0
let deadline = Date().addingTimeInterval(timeoutSeconds)

while Date() < deadline {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "lzhl.codexAppBar")
    if let app = apps.first {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let windows: [AXUIElement] = attr(appElement, kAXWindowsAttribute),
           let window = windows.first(where: { (attr($0, kAXTitleAttribute) as String?) == "OpenAI OAuth" }),
           let authURL = findAuthURL(in: window) {
            print(authURL)
            exit(0)
        }
    }

    Thread.sleep(forTimeInterval: 0.2)
}

fputs("Timed out waiting for the OpenAI OAuth window auth URL.\n", stderr)
exit(1)
