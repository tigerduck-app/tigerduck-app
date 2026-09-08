#if os(iOS)
import SwiftUI
import Testing
import UIKit

@testable import TigerDuck

/// The class table's header capsule and the Calendar "Today" button sit one
/// tab apart and are meant to read as the same size control. Their heights
/// come from unrelated places, though — Today's from `GlassTextButtonModifier`,
/// which the system sizes and which resolves differently per OS version, and
/// the capsule's from an explicit frame — so nothing but this test stops them
/// drifting.
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
        let cellHeight: CGFloat = if #available(iOS 26, *) { 28 } else { 40 }
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

    @Test("the class table header capsule is the same height as Today")
    func capsuleMatchesTodayButton() {
        let today = renderedHeight(todayButton)
        let capsule = renderedHeight(headerCapsule)
        // A point of slack: Today's height falls out of the system's button
        // metrics and is not a round number (28.33 on iOS 26, 40.33 on
        // iOS 18), so demanding equality would pin us to a value Apple owns.
        #expect(
            abs(capsule - today) <= 1,
            "capsule \(capsule)pt vs Today \(today)pt on iOS \(UIDevice.current.systemVersion) — they should read as one size"
        )
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
