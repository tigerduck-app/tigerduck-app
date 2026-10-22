import Foundation

extension Double {
    var creditsText: String {
        formatted(.number.precision(.fractionLength(0...2)))
    }
}
