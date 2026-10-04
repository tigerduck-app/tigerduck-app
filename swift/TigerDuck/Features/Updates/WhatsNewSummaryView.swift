#if os(iOS)
import SwiftUI

/// The last page of the What's New flow: the release title and its
/// highlights as rows — tinted SF Symbol, headline, a line of detail —
/// the layout Apple's own apps use for What's New. Its Continue button
/// lives in ``WhatsNewFlowView``'s footer with every other page's.
///
/// Content comes from `whatsnew.json` via ``WhatsNewRepository``. An
/// entry written before rows had symbols and headlines (`highlights`)
/// renders each sentence as a bulleted body-only row.
struct WhatsNewSummaryContent: View {
    let entry: WhatsNewRepository.ResolvedWhatsNew

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.xxl) {
                Text(entry.title)
                    .font(TigerDuckTheme.Typography.largeTitle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xl) {
                    ForEach(Array(entry.items.enumerated()), id: \.offset) { offset, item in
                        WhatsNewSummaryRow(item: item)
                            // Rows settle in one after another on first
                            // show; Reduce Motion keeps the fade, drops
                            // the slide.
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared || reduceMotion ? 0 : 12)
                            .animation(
                                .smooth(duration: 0.45).delay(0.1 + Double(offset) * 0.07),
                                value: hasAppeared
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, TigerDuckTheme.Spacing.xl)
            .padding(.top, TigerDuckTheme.Spacing.xxl)
            .padding(.bottom, TigerDuckTheme.Spacing.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { hasAppeared = true }
    }
}

private struct WhatsNewSummaryRow: View {
    let item: WhatsNewRepository.ResolvedWhatsNew.Item

    var body: some View {
        if let symbol = item.symbol {
            HStack(spacing: TigerDuckTheme.Spacing.lg) {
                Image(systemName: symbol)
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 44)
                    .accessibilityHidden(true)
                text
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.md) {
                // Filled-circle bullet lined up with the first text
                // baseline, so wrapped lines indent under the text
                // rather than the bullet.
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.tint)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                    .accessibilityHidden(true)
                text
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = item.title {
                Text(title)
                    .font(.headline)
            }
            if let body = item.body {
                // A body under a headline is the detail line; a body on
                // its own is the whole row and reads at full strength.
                Text(body)
                    .font(item.title == nil ? .body : .subheadline)
                    .foregroundStyle(item.title == nil ? .primary : .secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
