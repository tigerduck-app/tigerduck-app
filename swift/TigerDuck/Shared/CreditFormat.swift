import Foundation

extension Double {
    /// A credit count written the way a student writes it: "3", "1.5", "0.5"
    /// — never "3.0".
    ///
    /// NTUST issues half credits, so credits are a `Double` everywhere rather
    /// than the `Int` they used to be (which silently turned a 0.5-credit
    /// course into a 0-credit one). Nine courses in ten are still whole
    /// numbers, and a trailing ".0" on all of them is noise. Locale-aware, so
    /// the half lands as "0,5" where that is how a number is written.
    var creditsText: String {
        formatted(.number.precision(.fractionLength(0...2)))
    }
}
