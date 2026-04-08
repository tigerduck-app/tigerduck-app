import SwiftUI

struct WidgetGridView: View {
    @Binding var widgets: [WidgetItem]
    @Binding var isEditing: Bool
    var onRemove: ((WidgetItem) -> Void)? = nil
    var onTap: ((AppFeature) -> Void)? = nil
    var onAdd: (() -> Void)? = nil
    var onReorder: (() -> Void)? = nil

    @State private var draggingWidget: WidgetItem?
    @State private var dragLocation: CGPoint = .zero
    @State private var fingerOffset: CGSize = .zero
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var didReorder = false

    private let columns = [
        GridItem(.flexible(), spacing: TigerDuckTheme.Spacing.md),
        GridItem(.flexible(), spacing: TigerDuckTheme.Spacing.md),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: TigerDuckTheme.Spacing.md) {
            ForEach(widgets) { widget in
                widgetCell(widget)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .coordinateSpace(name: "widgetGrid")
        .onPreferenceChange(WidgetCellFrameKey.self) { cellFrames = $0 }
        .overlay {
            floatingCard
        }
    }

    // MARK: - Cell

    @ViewBuilder
    private func widgetCell(_ widget: WidgetItem) -> some View {
        let card = cardContent(widget)

        if isEditing {
            card.gesture(dragGesture(for: widget))
        } else {
            card
                .onTapGesture { onTap?(widget.feature) }
                .onLongPressGesture {
                    withAnimation(.smoothSpring) { isEditing = true }
                }
        }
    }

    @ViewBuilder
    private func cardContent(_ widget: WidgetItem) -> some View {
        WidgetContainer(feature: widget.feature, size: widget.size) {
            SimpleWidgetContent(feature: widget.feature, size: widget.size)
        }
        .overlay(alignment: .topLeading) {
            if isEditing {
                Button { onRemove?(widget) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .red)
                        .font(.title3)
                }
                .offset(x: -6, y: -6)
            }
        }
        .wiggling(isEditing)
        .opacity(draggingWidget?.id == widget.id ? 0 : 1)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: WidgetCellFrameKey.self,
                    value: [widget.id: geo.frame(in: .named("widgetGrid"))]
                )
            }
        )
    }

    // MARK: - Drag gesture

    private func dragGesture(for widget: WidgetItem) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("widgetGrid"))
            .onChanged { value in
                if draggingWidget == nil {
                    draggingWidget = widget
                    if let frame = cellFrames[widget.id] {
                        fingerOffset = CGSize(
                            width: value.startLocation.x - frame.midX,
                            height: value.startLocation.y - frame.midY
                        )
                    }
                    dragLocation = value.location
                    return
                }
                dragLocation = value.location
                reorderIfNeeded(at: value.location)
            }
            .onEnded { _ in
                withAnimation(.smoothSpring) {
                    draggingWidget = nil
                }
                if didReorder {
                    onReorder?()
                    didReorder = false
                }
            }
    }

    // MARK: - Floating card overlay

    @ViewBuilder
    private var floatingCard: some View {
        if let dragging = draggingWidget,
           let frame = cellFrames[dragging.id] {
            WidgetContainer(feature: dragging.feature, size: dragging.size) {
                SimpleWidgetContent(feature: dragging.feature, size: dragging.size)
            }
            .frame(width: frame.width)
            .scaleEffect(1.05)
            .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 8)
            .position(
                x: dragLocation.x - fingerOffset.width,
                y: dragLocation.y - fingerOffset.height
            )
            .allowsHitTesting(false)
        }
    }

    // MARK: - Reorder

    private func reorderIfNeeded(at point: CGPoint) {
        guard let dragging = draggingWidget,
              let fromIndex = widgets.firstIndex(where: { $0.id == dragging.id }) else { return }

        for (id, frame) in cellFrames where id != dragging.id {
            if frame.contains(point),
               let toIndex = widgets.firstIndex(where: { $0.id == id }) {
                withAnimation(.smoothSpring) {
                    widgets.move(fromOffsets: IndexSet(integer: fromIndex),
                                 toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
                }
                didReorder = true
                return
            }
        }
    }
}

// MARK: - Cell frame tracking

private struct WidgetCellFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Wiggle modifier

extension View {
    func wiggling(_ isWiggling: Bool) -> some View {
        modifier(WiggleModifier(isWiggling: isWiggling))
    }
}

struct WiggleModifier: ViewModifier {
    let isWiggling: Bool
    @State private var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(isWiggling ? angle : 0))
            .onAppear {
                if isWiggling {
                    withAnimation(.linear(duration: 0.15).repeatForever(autoreverses: true)) {
                        angle = 1.5
                    }
                }
            }
            .onChange(of: isWiggling) { _, newValue in
                if newValue {
                    angle = -1.5
                    withAnimation(.linear(duration: 0.15).repeatForever(autoreverses: true)) {
                        angle = 1.5
                    }
                } else {
                    withAnimation(.quickSpring) {
                        angle = 0
                    }
                }
            }
    }
}
