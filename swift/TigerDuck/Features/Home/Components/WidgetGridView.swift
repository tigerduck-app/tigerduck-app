import SwiftUI
import UniformTypeIdentifiers

struct WidgetGridView: View {
    @Binding var widgets: [WidgetItem]
    @Binding var isEditing: Bool
    var onRemove: ((WidgetItem) -> Void)? = nil
    var onTap: ((AppFeature) -> Void)? = nil
    var onAdd: (() -> Void)? = nil

    @State private var draggingWidget: WidgetItem?

    private let columns = [
        GridItem(.flexible(), spacing: TigerDuckTheme.Spacing.md),
        GridItem(.flexible(), spacing: TigerDuckTheme.Spacing.md),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: TigerDuckTheme.Spacing.md) {
            ForEach(widgets) { widget in
                WidgetContainer(feature: widget.feature, size: widget.size) {
                    SimpleWidgetContent(feature: widget.feature, size: widget.size)
                }
                .overlay(alignment: .topLeading) {
                    if isEditing {
                        Button {
                            onRemove?(widget)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .red)
                                .font(.title3)
                        }
                        .offset(x: -6, y: -6)
                    }
                }
                .wiggling(isEditing)
                .opacity(draggingWidget?.id == widget.id ? 0.5 : 1)
                .onTapGesture {
                    if !isEditing {
                        onTap?(widget.feature)
                    }
                }
                .onLongPressGesture {
                    withAnimation(.smoothSpring) {
                        isEditing = true
                    }
                }
                .onDrag {
                    draggingWidget = widget
                    return NSItemProvider(object: widget.id as NSString)
                } preview: {
                    Color.clear.frame(width: 1, height: 1)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: WidgetDropDelegate(
                        targetWidget: widget,
                        widgets: $widgets,
                        draggingWidget: $draggingWidget
                    )
                )
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .onDrop(
            of: [UTType.text],
            delegate: WidgetBackgroundDropDelegate(draggingWidget: $draggingWidget)
        )
    }
}

// MARK: - Widget drop delegate

private struct WidgetDropDelegate: DropDelegate {
    let targetWidget: WidgetItem
    @Binding var widgets: [WidgetItem]
    @Binding var draggingWidget: WidgetItem?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingWidget,
              dragging.id != targetWidget.id,
              let fromIndex = widgets.firstIndex(where: { $0.id == dragging.id }),
              let toIndex = widgets.firstIndex(where: { $0.id == targetWidget.id }) else { return }
        withAnimation(.smoothSpring) {
            widgets.move(fromOffsets: IndexSet(integer: fromIndex),
                         toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingWidget = nil
        return true
    }
}

private struct WidgetBackgroundDropDelegate: DropDelegate {
    @Binding var draggingWidget: WidgetItem?

    func performDrop(info: DropInfo) -> Bool {
        draggingWidget = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

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
