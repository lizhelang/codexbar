import SwiftUI

/// 设置页面共用的选项行，与菜单面板使用同一种分隔箭头和悬停交互。
struct SettingsSelectionField<Value: Equatable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var showsLabel = true

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)], showsLabel: Bool = true) {
        self.title = title
        self._selection = selection
        self.options = options
        self.showsLabel = showsLabel
    }

    var body: some View {
        HStack(spacing: 12) {
            if self.showsLabel {
                Text(self.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 8)
            }
            RouteSelectionMenu(
                title: self.options.first(where: { $0.value == self.selection })?.title ?? "—",
                accessibilityLabel: self.title,
                items: self.options.enumerated().map { index, option in
                    RouteSelectionMenuItem(
                        id: String(index), title: option.title, isSelected: option.value == self.selection,
                        action: { self.selection = option.value }
                    )
                },
                fontSize: 12
            )
            .frame(maxWidth: 320, alignment: self.showsLabel ? .trailing : .leading)
        }
    }
}
