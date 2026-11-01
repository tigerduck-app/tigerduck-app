import Foundation

extension Array where Element == String {
    private static let periodOrderMap: [String: Int] =
        Dictionary(uniqueKeysWithValues: AppConstants.Periods.chronologicalOrder.enumerated().map { ($1, $0) })

    func timedPeriodsInOrder() -> [String] {
        let map = Self.periodOrderMap
        return filter { map[$0] != nil }.sorted { (map[$0] ?? 0) < (map[$1] ?? 0) }
    }
}
