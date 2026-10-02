import SwiftUI

/// A stable row of buttons whose selection plate moves without animating the page it controls.
struct SlidingGlassSelection<Value: Hashable, Label: View>: View {
    let values: [Value]
    let selection: Value
    let onSelect: (Value) -> Void
    let accessibilityIdentifier: (Value) -> String
    let spacing: CGFloat
    let cornerRadius: CGFloat
    let inset: CGFloat
    let showsTrack: Bool
    private let label: (Value, Bool) -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var selectionNamespace
    @State private var hoveredValue: Value?

    init(
        values: [Value],
        selection: Value,
        onSelect: @escaping (Value) -> Void,
        accessibilityIdentifier: @escaping (Value) -> String = { _ in "" },
        spacing: CGFloat = 0,
        cornerRadius: CGFloat = 8,
        inset: CGFloat = 3,
        showsTrack: Bool = true,
        @ViewBuilder label: @escaping (Value, Bool) -> Label
    ) {
        self.values = values
        self.selection = selection
        self.onSelect = onSelect
        self.accessibilityIdentifier = accessibilityIdentifier
        self.spacing = spacing
        self.cornerRadius = cornerRadius
        self.inset = inset
        self.showsTrack = showsTrack
        self.label = label
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(values, id: \.self) { value in
                let isSelected = value == selection
                Button {
                    guard value != selection else { return }
                    onSelect(value)
                } label: {
                    label(value, isSelected)
                        .frame(maxWidth: .infinity)
                        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .background {
                    if isSelected {
                        selectionPlate
                            .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                    } else if hoveredValue == value {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.055))
                    }
                }
                .onHover { isHovered in
                    if isHovered {
                        hoveredValue = value
                    } else if hoveredValue == value {
                        hoveredValue = nil
                    }
                }
                .accessibilityIdentifier(accessibilityIdentifier(value))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(inset)
        .background {
            if showsTrack {
                RoundedRectangle(cornerRadius: cornerRadius + inset, style: .continuous)
                    .fill(MenuSurface.raised.opacity(0.38))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius + inset, style: .continuous)
                            .strokeBorder(MenuSurface.line, lineWidth: 1)
                    }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88), value: selection)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredValue)
    }

    private var selectionPlate: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(reduceTransparency ? AnyShapeStyle(MenuSurface.raised) : AnyShapeStyle(.ultraThinMaterial))
            .overlay {
                shape.fill(MenuSurface.raised.opacity(0.65))
            }
            .overlay {
                shape.fill(Color.primary.opacity(0.08))
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.24), Color.white.opacity(0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.7
                )
            }
            .shadow(color: .black.opacity(0.09), radius: 2, y: 1)
            .allowsHitTesting(false)
    }
}
