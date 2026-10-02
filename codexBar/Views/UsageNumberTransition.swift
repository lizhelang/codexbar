import SwiftUI

/// Keep animation local to the value, so a new usage snapshot never animates the surrounding list layout.
struct UsageNumberTransition: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14, *), !self.reduceMotion {
            content
                .contentTransition(.numericText(value: self.value))
                .animation(.easeInOut(duration: 0.28), value: self.value)
        } else {
            content
        }
    }
}
