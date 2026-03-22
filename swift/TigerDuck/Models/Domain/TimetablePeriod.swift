import Foundation

struct TimetablePeriod: Identifiable, Hashable {
    let id: String // e.g. "1", "2", ... "A", "B", "C"
    let startTime: String
    let endTime: String

    var displayLabel: String { id }

    static let standard: [TimetablePeriod] = AppConstants.Periods.defaultVisible.compactMap { periodID in
        guard let times = AppConstants.PeriodTimes.mapping[periodID] else { return nil }
        return TimetablePeriod(id: periodID, startTime: times.start, endTime: times.end)
    }

    static let all: [TimetablePeriod] = {
        let order = AppConstants.Periods.chronologicalOrder
        return order.compactMap { periodID in
            guard let times = AppConstants.PeriodTimes.mapping[periodID] else { return nil }
            return TimetablePeriod(id: periodID, startTime: times.start, endTime: times.end)
        }
    }()
}
