import SwiftUI
import XCTest
@testable import TigerDuckWatch_Watch_App

final class WatchVisualStylePolicyTests: XCTestCase {

    /// TAT changes only the phone's class table, so the Watch draws TigerDuck's cards.
    @MainActor
    func test_tat_drawsTigerDucksCards() {
        let tat = WatchVisualStylePolicy(preset: .tat)
        let tigerDuck = WatchVisualStylePolicy(preset: .default)

        XCTAssertEqual(tat.usesTintedCardSurface, tigerDuck.usesTintedCardSurface)
        XCTAssertEqual(tat.cardBackground(for: .orange), tigerDuck.cardBackground(for: .orange))
    }
}
