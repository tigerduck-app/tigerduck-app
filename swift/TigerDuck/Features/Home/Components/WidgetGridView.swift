import SwiftUI

struct WidgetGridView: View {
    @Binding var widgets: [WidgetItem]
    @Binding var isEditing: Bool
    let dragContainerID: String
    var onRemove: ((WidgetItem) -> Void)? = nil
    var onTap: ((AppFeature) -> Void)? = nil
    var onAdd: (() -> Void)? = nil
    var onReorder: (() -> Void)? = nil

    @State private var activeWidgetDrag: ReorderDragPayload?
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
        .onDrop(
            of: [.tigerDuckReorderPayload],
            delegate: ReorderContainerDropDelegate(
                expectedKind: .widget,
                containerID: dragContainerID,
                activePayload: $activeWidgetDrag,
                didReorder: $didReorder,
                onPersist: { onReorder?() }
            )
        )
        .onChange(of: isEditing) { _, editing in
            if !editing {
                finishWidgetDrag()
            }
        }
        .onDisappear {
            finishWidgetDrag()
        }
    }

    // MARK: - Cell

    @ViewBuilder
    private func widgetCell(_ widget: WidgetItem) -> some View {
        let card = cardContent(widget)

        if isEditing {
            let payload = widgetDragPayload(for: widget)
            card
                .draggable(payload) {
                    WidgetDragPreview(widget: widget)
                        .onAppear { activeWidgetDrag = payload }
                }
                .onDrop(
                    of: [.tigerDuckReorderPayload],
                    delegate: ReorderDropDelegate(
                        targetID: widget.id,
                        expectedKind: .widget,
                        containerID: dragContainerID,
                        activePayload: $activeWidgetDrag,
                        didReorder: $didReorder,
                        currentIDs: { widgets.map(\.id) },
                        moveAction: { fromOffsets, destination in
                            widgets.move(fromOffsets: fromOffsets, toOffset: destination)
                        },
                        onPersist: { onReorder?() }
                    )
                )
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
        .opacity(activeWidgetDrag?.id == widget.id ? 0.35 : 1)
    }

    private func widgetDragPayload(for widget: WidgetItem) -> ReorderDragPayload {
        ReorderDragPayload(
            id: widget.id,
            kind: .widget,
            containerID: dragContainerID
        )
    }

    private func finishWidgetDrag() {
        ReorderDropSupport.finalizeDrop(
            activePayload: $activeWidgetDrag,
            didReorder: $didReorder,
            onPersist: { onReorder?() }
        )
    }
}

private struct WidgetDragPreview: View {
    let widget: WidgetItem

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: widget.feature.iconName)
                .font(.title3)
                .foregroundStyle(Color.accentPrimary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(widget.feature.displayName)
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Text(widget.size.rawValue.capitalized)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(TigerDuckTheme.Spacing.lg)
        .frame(width: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        )
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
