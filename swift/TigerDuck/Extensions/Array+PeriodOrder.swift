import Foundation

extension Array where Element == String {
    private static var periodOrderMap: [String: Int] {
        Dictionary(uniqueKeysWithValues: AppConstants.Periods.chronologicalOrder.enumerated().map { ($1, $0) })
    }

    /// Sort period IDs by chronological order (1,2,3,4,5,6,7,8,9,10,A,B,C,D)
    func sortedByPeriodOrder() -> [String] {
        let map = Self.periodOrderMap
        return sorted { a, b in
            (map[a] ?? Int.max) < (map[b] ?? Int.max)
        }
    }
}
