#if os(iOS)
import SwiftUI

/// Sheet shown either (a) automatically on first launch after the
/// installed version moves past `lastShownWhatsNewVersion`, or (b)
/// manually from Settings → What's New (which always opens the latest
/// authored entry regardless of seen-state).
///
/// Content comes from the bundled `whatsnew.json` via
/// ``WhatsNewRepository``, not from in-code Swift constants — devs
/// update the JSON before tagging a release. The shape mirrors the
/// Android dialog: a one-line title plus a vertical list of bullet
/// highlights. Keeping the bullets text-only (no per-row SF Symbols)
/// matches the Android port and means a new release doesn't need a
/// designer pass to pick icons.
struct WhatsNewSheetView: View {
    let entry: WhatsNewRepository.ResolvedWhatsNew
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Hero icon + version banner. The hero stays a constant
            // sparkles glyph across releases — varying it per release
            // would force a designer pass for every What's New, which
            // is the kind of friction the JSON-driven content split
            // was meant to remove.
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(.tint)
                Text(entry.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 28)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(entry.highlights.indices, id: \.self) { idx in
                        WhatsNewBulletRow(text: entry.highlights[idx])
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Sticky Continue anchor. Apple's What's New pattern keeps
            // the dismiss button visible regardless of scroll position
            // so a user with a long release-notes list never has to
            // scroll to find the way out.
            Button {
                onAcknowledge()
            } label: {
                Text(String(localized: "whats_new_continue"))
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

private struct WhatsNewBulletRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Filled-circle bullet at the leading edge — lines up with
            // the first text baseline so wrapped lines indent under the
            // text rather than the bullet.
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
#endif
