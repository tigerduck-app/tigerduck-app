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
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: ReorderDropDelegate(
                        targetItem: widget,
                        items: $widgets,
                        draggingItem: $draggingWidget
                    )
                )
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
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
