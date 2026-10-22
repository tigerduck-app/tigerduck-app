#if os(iOS)
import SwiftUI
import Testing
import UIKit

@testable import TigerDuck

@MainActor
@Suite("Header control metrics")
struct HeaderControlMetricsTests {

    private final class Box: @unchecked Sendable { var height: CGFloat = -1 }

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

    private var todayButton: some View {
        Button {} label: {
            Text(String(localized: "calendar_today"))
                .font(.caption.weight(.semibold))
        }
        .modifier(GlassTextButtonModifier())
    }

    private var headerCapsule: some View {
        let cellHeight: CGFloat = if #available(iOS 26, *) { 36 } else { 40 }
        let menu = Menu {
            Button("") {}
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.medium))
                .frame(width: cellHeight, height: cellHeight)
        }
        return Group {
            if #available(iOS 26, *) {
                menu.glassEffect(.regular.interactive(), in: .circle)
            } else {
                menu.background(Circle().fill(Color(uiColor: .secondarySystemFill)))
            }
        }
    }

    @Test("the header button keeps its intended relationship to Today")
    func capsuleTracksTodayButton() {
        let today = renderedHeight(todayButton)
        let capsule = renderedHeight(headerCapsule)
        let os = UIDevice.current.systemVersion

        if #available(iOS 26, *) {
            let ratio = capsule / today
            #expect(
                ratio > 1.15 && ratio < 1.45,
                "capsule \(capsule)pt is \(ratio)x Today \(today)pt on iOS \(os) — expected ~1.3x"
            )
        } else {
            #expect(
                abs(capsule - today) <= 1,
                "capsule \(capsule)pt vs Today \(today)pt on iOS \(os) — they should read as one size"
            )
        }

        #expect(capsule >= today - 1, "capsule \(capsule)pt is shorter than Today \(today)pt")
    }

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
