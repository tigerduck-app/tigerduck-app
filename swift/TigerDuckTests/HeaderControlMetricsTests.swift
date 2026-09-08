#if os(iOS)
import SwiftUI
import Testing
import UIKit

@testable import TigerDuck

/// The class table's header capsule and the Calendar "Today" button sit one
/// tab apart and are meant to read as the same size control. Their heights
/// come from two unrelated places, though — Today's from `.buttonStyle(.glass)`,
/// which the system sizes, and the capsule's from an explicit frame — so
/// nothing but this test stops them drifting when either is touched.
@MainActor
@Suite("Header control metrics")
struct HeaderControlMetricsTests {

    private func height(_ view: some View) -> CGFloat {
        let host = UIHostingController(rootView: view)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(
            in: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        ).height
    }

    /// Mirrors `CalendarTabView`'s Today button.
    private var todayButton: some View {
        Button {} label: {
            Text(String(localized: "calendar_today"))
                .font(.caption.weight(.semibold))
        }
        .modifier(GlassTextButtonModifier())
    }

    /// Mirrors `ClassTableView.headerActions`.
    @available(iOS 26, *)
    private var headerCapsule: some View {
        HStack(spacing: 0) {
            ForEach(["arrow.triangle.2.circlepath", "plus"], id: \.self) { name in
                Button {} label: {
                    Image(systemName: name)
                        .font(.subheadline.weight(.medium))
                        .frame(width: 40, height: 28)
                }
            }
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    @Test("the class table header capsule is the same height as Today")
    @available(iOS 26, *)
    func capsuleMatchesTodayButton() {
        let today = height(todayButton)
        let capsule = height(headerCapsule)
        // A point of slack: Today's height falls out of the system's glass
        // button metrics and is not a round number (28.33 on iOS 26.5), so
        // demanding equality would pin us to a value Apple owns.
        #expect(
            abs(capsule - today) <= 1,
            "capsule \(capsule)pt vs Today \(today)pt — they should read as one size"
        )
    }

    /// The outer heights matching is not enough on its own: a `.body` glyph
    /// in a 28pt capsule is 17pt against Today's 14.33pt label, which reads
    /// as a heavier control even when the pill around it is identical.
    @Test("the header glyph carries the same optical weight as Today's label")
    func glyphMatchesTodayLabel() {
        let label = height(Text(String(localized: "calendar_today")).font(.caption.weight(.semibold)))
        let glyph = height(Image(systemName: "plus").font(.subheadline.weight(.medium)))
        #expect(
            abs(glyph - label) <= 1.5,
            "glyph \(glyph)pt vs Today label \(label)pt"
        )
    }
}
#endif
