#if os(iOS)
import SwiftUI

/// The scrolling body of one feature page — everything above the page
/// dots. The buttons below belong to ``WhatsNewFlowView``, which keeps
/// them in place while pages slide.
struct WhatsNewPageContentView: View {
    let page: WhatsNewPage
    let context: WhatsNewPageContext

    var body: some View {
        switch page.kind {
        case .feature(let content), .optIn(let content, _, _, _), .permission(let content, _, _, _):
            WhatsNewTemplateBody(content: content) { EmptyView() }
        case .choice(let content, let options, let current, let select):
            WhatsNewTemplateBody(content: content) {
                WhatsNewChoicePicker(options: options, initial: current(context.appState)) {
                    select(context.appState, $0)
                }
            }
        case .toggle(let content, let label, let get, let set):
            WhatsNewTemplateBody(content: content) {
                WhatsNewToggleRow(label: String(localized: label), initial: get(context.appState)) {
                    set(context.appState, $0)
                }
            }
        case .custom(_, let build):
            build(context)
        }
    }
}

/// Demo, title and body, centred — the shared shape of every template —
/// with a slot underneath for the template's own control.
private struct WhatsNewTemplateBody<Accessory: View>: View {
    let content: WhatsNewPage.Content
    @ViewBuilder let accessory: Accessory

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.xl) {
                    if let visual = content.visual {
                        WhatsNewVisualView(visual: visual)
                    }
                    VStack(spacing: TigerDuckTheme.Spacing.md) {
                        Text(String(localized: content.title))
                            .font(.title.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text(String(localized: content.body))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    accessory
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, TigerDuckTheme.Spacing.xl)
                .padding(.vertical, TigerDuckTheme.Spacing.lg)
                // Centred in the page while it fits, so a short page
                // doesn't leave its gap all above the buttons; once
                // Dynamic Type outgrows the page it scrolls from the top.
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

struct WhatsNewVisualView: View {
    let visual: WhatsNewVisual

    var body: some View {
        switch visual {
        case .symbol(let name, let effect):
            Image(systemName: name)
                .font(.system(size: 76))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .modifier(WhatsNewSymbolEffectModifier(effect: effect))
                .frame(height: 120)
                .accessibilityHidden(true)
        case .view(let demo):
            demo()
                .frame(maxWidth: .infinity)
                .frame(height: 240)
        }
    }
}

/// Loops the page's symbol effect. Reduce Motion stills the symbol
/// rather than swapping in a subtler effect — the text carries the page.
private struct WhatsNewSymbolEffectModifier: ViewModifier {
    let effect: WhatsNewSymbolEffect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            switch effect {
            case .none:
                content
            case .bounce:
                content.symbolEffect(.bounce, options: .repeat(.periodic(delay: 1.5)))
            case .pulse:
                content.symbolEffect(.pulse, options: .repeat(.continuous))
            case .wiggle:
                content.symbolEffect(.wiggle, options: .repeat(.periodic(delay: 1.5)))
            case .breathe:
                content.symbolEffect(.breathe, options: .repeat(.continuous))
            case .rotate:
                content.symbolEffect(.rotate, options: .repeat(.periodic(delay: 1)))
            case .variableColor:
                content.symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
            }
        }
    }
}

/// Side-by-side cards, one per look. A tap applies the pick at once, so
/// leaving the page by any route keeps it.
private struct WhatsNewChoicePicker: View {
    let options: [WhatsNewPage.ChoiceOption]
    let select: (String) -> Void
    @State private var selection: String

    init(options: [WhatsNewPage.ChoiceOption], initial: String, select: @escaping (String) -> Void) {
        self.options = options
        self.select = select
        _selection = State(initialValue: initial)
    }

    var body: some View {
        HStack(alignment: .top, spacing: TigerDuckTheme.Spacing.lg) {
            ForEach(options) { option in
                let isSelected = option.id == selection
                Button {
                    selection = option.id
                    select(option.id)
                } label: {
                    VStack(spacing: TigerDuckTheme.Spacing.sm) {
                        option.preview()
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                        lineWidth: isSelected ? 3 : 1
                                    )
                            }
                        Text(String(localized: option.title))
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .animation(.snappy, value: isSelected)
            }
        }
    }
}

/// A switch under the demo, applied live as it flips.
private struct WhatsNewToggleRow: View {
    let label: String
    let set: (Bool) -> Void
    @State private var isOn: Bool

    init(label: String, initial: Bool, set: @escaping (Bool) -> Void) {
        self.label = label
        self.set = set
        _isOn = State(initialValue: initial)
    }

    var body: some View {
        Toggle(label, isOn: $isOn)
            .onChange(of: isOn) { _, newValue in set(newValue) }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.vertical, TigerDuckTheme.Spacing.md)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
            )
    }
}

struct WhatsNewPageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            ForEach(0..<count, id: \.self) { step in
                Circle()
                    .fill(step == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityHidden(true)
    }
}
#endif
