import SwiftUI
import XCTest
@testable import TigerDuckWatch_Watch_App

final class WatchVisualStylePolicyTests: XCTestCase {

    @MainActor
    func test_tat_drawsTigerDucksCards() {
        let tat = WatchVisualStylePolicy(preset: .tat)
        let tigerDuck = WatchVisualStylePolicy(preset: .default)

        XCTAssertEqual(tat.usesTintedCardSurface, tigerDuck.usesTintedCardSurface)
        XCTAssertEqual(tat.cardBackground(for: .orange), tigerDuck.cardBackground(for: .orange))
    }
}
