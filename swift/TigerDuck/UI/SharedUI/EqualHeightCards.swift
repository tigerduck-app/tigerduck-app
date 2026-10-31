import SwiftUI

struct MaxCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// `.onDisappear`, because `TabView` keeps `@State` across tab switches and a
/// once-tall child, like the "current class" card, would otherwise keep it.
struct EqualHeightHStack<Content: View>: View {
    var alignment: VerticalAlignment = .top
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    @State private var lockedHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: alignment, spacing: spacing) {
            content()
        }
        .frame(height: lockedHeight > 0 ? lockedHeight : nil, alignment: .top)
        .background(measurementLayer)
        .onPreferenceChange(MaxCardHeightKey.self) { newValue in
            if newValue > lockedHeight { lockedHeight = newValue }
        }
        .onDisappear { lockedHeight = 0 }
    }

    private var measurementLayer: some View {
        HStack(alignment: alignment, spacing: spacing) {
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: MaxCardHeightKey.self, value: proxy.size.height)
            }
        )
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
