#if os(iOS)
import SwiftUI
import Testing
import UIKit

@testable import TigerDuck

/// The class table's header capsule is sized against the Calendar "Today"
/// button — matching it below iOS 26, and deliberately ~1.3x it on 26, where
/// `.buttonStyle(.glass)` is a much tighter control than a capsule holding
/// two icon targets wants to be.
///
/// Today's height is Apple's number, not ours, and it resolves differently
/// per OS version, so nothing but this test stops the relationship drifting
/// when either side is touched.
///
/// Heights are measured from a laid-out window rather than `sizeThatFits`.
/// The ideal size a hosting controller reports is not what a button style
/// actually lays out to: on iOS 18 Today reports one thing and renders
/// 40.33pt, and an earlier version of this test passed on iOS 26 while the
/// two were 12pt apart on iOS 18.
@MainActor
@Suite("Header control metrics")
struct HeaderControlMetricsTests {

    private final class Box: @unchecked Sendable { var height: CGFloat = -1 }

    /// Real laid-out height, taken from a `GeometryReader` inside a window.
    private func renderedHeight(_ view: some View) -> CGFloat {
        let box = Box()
        let probe = view.background(
            GeometryReader { geometry -> Color in
                box.height = geometry.size.height
                return Color.clear
            }
        )
        let host = UIHostingController(
            rootView: VStack(spacing: 0) { probe; Spacer() }
                .frame(width: 400, height: 300)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return box.height
    }

    /// Mirrors `CalendarTabView`'s Today button.
    private var todayButton: some View {
        Button {} label: {
            Text(String(localized: "calendar_today"))
                .font(.caption.weight(.semibold))
        }
        .modifier(GlassTextButtonModifier())
    }

    /// Mirrors `ClassTableView.headerActions`, including its per-OS height.
    private var headerCapsule: some View {
        let cellHeight: CGFloat = if #available(iOS 26, *) { 36 } else { 40 }
        let row = HStack(spacing: 0) {
            ForEach(["arrow.triangle.2.circlepath", "plus"], id: \.self) { name in
                Button {} label: {
                    Image(systemName: name)
                        .font(.subheadline.weight(.medium))
                        .frame(width: 40, height: cellHeight)
                }
            }
        }
        return Group {
            if #available(iOS 26, *) {
                row.glassEffect(.regular.interactive(), in: .capsule)
            } else {
                row.background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
            }
        }
    }

    @Test("the header capsule keeps its intended relationship to Today")
    func capsuleTracksTodayButton() {
        let today = renderedHeight(todayButton)
        let capsule = renderedHeight(headerCapsule)
        let os = UIDevice.current.systemVersion

        if #available(iOS 26, *) {
            // Deliberately taller than Today here: `.buttonStyle(.glass)` is a
            // tight control sized for one short word, and at its 28.33pt the
            // glass behind two icon targets read as a sliver. ~1.3x. The band
            // is wide because Today's height is Apple's number, not ours — it
            // exists to catch the capsule collapsing back to Today's size or
            // running away from it, not to pin a ratio to two decimals.
            let ratio = capsule / today
            #expect(
                ratio > 1.15 && ratio < 1.45,
                "capsule \(capsule)pt is \(ratio)x Today \(today)pt on iOS \(os) — expected ~1.3x"
            )
        } else {
            // Below 26 both are the same kind of padded bordered control, so
            // they should simply agree. This is the case that regressed: a
            // constant tuned on iOS 26 left them 12pt apart here.
            #expect(
                abs(capsule - today) <= 1,
                "capsule \(capsule)pt vs Today \(today)pt on iOS \(os) — they should read as one size"
            )
        }

        // True on every OS: whatever the reference, the capsule is never the
        // shorter of the two. That is the direction the original bug went.
        #expect(capsule >= today - 1, "capsule \(capsule)pt is shorter than Today \(today)pt")
    }

    /// Matching outer heights is not enough on its own: a `.body` glyph in
    /// the capsule is 17pt against Today's 14.33pt label, which reads as a
    /// heavier control even when the pill around it is identical.
    @Test("the header glyph carries the same optical weight as Today's label")
    func glyphMatchesTodayLabel() {
        let label = renderedHeight(
            Text(String(localized: "calendar_today")).font(.caption.weight(.semibold))
        )
        let glyph = renderedHeight(
            Image(systemName: "plus").font(.subheadline.weight(.medium))
        )
        #expect(abs(glyph - label) <= 1.5, "glyph \(glyph)pt vs Today label \(label)pt")
    }
}
#endif
