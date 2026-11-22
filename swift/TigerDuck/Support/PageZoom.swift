import Foundation

/// A page zoom in percent and the steps it moves through.
nonisolated struct PageZoom: Sendable {
    static let standard = 100
    /// Safari's page zoom steps, for the TigerDuck browser.
    static let browser = PageZoom(steps: [50, 75, 85, 100, 115, 125, 150, 175, 200])
    /// School Mail's text size, from 50% to 200% in tens.
    static let mail = PageZoom(steps: Array(stride(from: 50, through: 200, by: 10)))

    let steps: [Int]

    /// The next step up, or nil at the largest; a value between steps goes to the one above it.
    func larger(than percent: Int) -> Int? { steps.first { $0 > percent } }

    func smaller(than percent: Int) -> Int? { steps.last { $0 < percent } }

    func clamped(_ percent: Int) -> Int { min(max(percent, steps[0]), steps[steps.count - 1]) }

    static func text(_ percent: Int) -> String { (Double(percent) / 100).formatted(.percent) }
}
