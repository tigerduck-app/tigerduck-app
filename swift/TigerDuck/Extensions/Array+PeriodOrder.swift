import Foundation

extension Array where Element == String {
    private static let periodOrderMap: [String: Int] =
        Dictionary(uniqueKeysWithValues: AppConstants.Periods.chronologicalOrder.enumerated().map { ($1, $0) })

    func sortedByPeriodOrder() -> [String] {
        let map = Self.periodOrderMap
        return sorted { a, b in
            (map[a] ?? Int.max) < (map[b] ?? Int.max)
        }
    }
}
