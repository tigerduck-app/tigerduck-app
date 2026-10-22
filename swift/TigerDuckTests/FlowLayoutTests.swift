#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct FlowLayoutTests {
    @Test func itemsKeepTheirLineInAHairLessThanTheWidthTheyReported() {
        let host = UIHostingController(rootView: FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(0..<3, id: \.self) { _ in Color.clear.frame(width: 30.3, height: 10) }
        })

        let reported = host.sizeThatFits(in: CGSize(width: 1000, height: CGFloat.infinity))
        let refit = host.sizeThatFits(in: CGSize(width: reported.width - 0.2, height: CGFloat.infinity))

        #expect(reported.height == 10)
        #expect(refit.height == reported.height)
    }
}
#endif
