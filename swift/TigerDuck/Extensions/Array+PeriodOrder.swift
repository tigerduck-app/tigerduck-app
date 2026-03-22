import Foundation

extension Array where Element == String {
    /// Sort period IDs by chronological order (1,2,3,4,5,6,7,8,9,10,A,B,C,D)
    func sortedByPeriodOrder() -> [String] {
        let order = AppConstants.Periods.chronologicalOrder
        return sorted { a, b in
            (order.firstIndex(of: a) ?? Int.max) < (order.firstIndex(of: b) ?? Int.max)
        }
    }
}
