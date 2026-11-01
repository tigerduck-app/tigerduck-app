import Foundation
import TigerDuckCore

struct TimeSliderLayout {
    private(set) var lanes: [String: TimeSliderLane] = [:]
    private var anchors: [(time: Date, x: CGFloat)] = []

    init(slots: [CourseTimeSlot] = []) {
        lanes = Self.lanes(for: slots)
        anchors = Self.anchors(for: slots)
    }

    private static func anchors(for slots: [CourseTimeSlot]) -> [(time: Date, x: CGFloat)] {
        let intervals = busyIntervals(slots)
        guard !intervals.isEmpty else { return [] }

        let ppm = TimeSliderMetrics.pointsPerMinute
        let refMin = TimeSliderMetrics.logarithmicReferenceMinutes
        let minGap = TimeSliderMetrics.minimumGapPoints
        let maxGap = TimeSliderMetrics.maximumGapPoints
        let dayGap = TimeSliderMetrics.dayBoundaryGapPoints

        var result: [(time: Date, x: CGFloat)] = []
        var x: CGFloat = 0

        let paddingBefore = compressedGapWidth(
            minutes: 60, refMin: refMin, ppm: ppm, minGap: minGap, maxGap: maxGap
        )
        result.append((time: intervals[0].start.addingTimeInterval(-3600), x: x))
        x += paddingBefore

        for (i, slot) in intervals.enumerated() {
            result.append((time: slot.start, x: x))

            let durationMin = slot.end.timeIntervalSince(slot.start) / 60
            x += CGFloat(durationMin) * ppm

            result.append((time: slot.end, x: x))

            if i + 1 < intervals.count {
                let next = intervals[i + 1]
                let gapMin = next.start.timeIntervalSince(slot.end) / 60

                let calendar = TaipeiTime.calendar
                let crossesDay = !calendar.isDate(slot.date, inSameDayAs: next.date)

                if crossesDay {
                    x += dayGap
                } else {
                    x += compressedGapWidth(
                        minutes: gapMin, refMin: refMin, ppm: ppm, minGap: minGap, maxGap: maxGap
                    )
                }
            }
        }

        let paddingAfter = compressedGapWidth(
            minutes: 60, refMin: refMin, ppm: ppm, minGap: minGap, maxGap: maxGap
        )
        x += paddingAfter
        if let last = intervals.last {
            result.append((time: last.end.addingTimeInterval(3600), x: x))
        }

        return result
    }

    private static func busyIntervals(_ slots: [CourseTimeSlot]) -> [(start: Date, end: Date, date: Date)] {
        var result: [(start: Date, end: Date, date: Date)] = []
        for slot in slots {
            if let last = result.last, slot.start < last.end {
                result[result.count - 1].end = max(last.end, slot.end)
            } else {
                result.append((start: slot.start, end: slot.end, date: slot.date))
            }
        }
        return result
    }

    static func lanes(for slots: [CourseTimeSlot]) -> [String: TimeSliderLane] {
        var lanes: [String: TimeSliderLane] = [:]
        var group: [CourseTimeSlot] = []
        var groupEnd = Date.distantPast
        func assignGroup() {
            guard group.count > 1 else { return }
            let assigned = OverlapLanes.assign(group.map { (start: $0.start, end: $0.end) })
            for (slot, lane) in zip(group, assigned.lanes) {
                lanes[slot.id] = TimeSliderLane(lane: lane, count: assigned.count)
            }
        }
        let byStart = slots.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
        for slot in byStart.map(\.element) {
            if slot.start < groupEnd {
                group.append(slot)
                groupEnd = max(groupEnd, slot.end)
            } else {
                assignGroup()
                group = [slot]
                groupEnd = slot.end
            }
        }
        assignGroup()
        return lanes
    }

    private static func compressedGapWidth(
        minutes: Double, refMin: Double, ppm: CGFloat, minGap: CGFloat, maxGap: CGFloat
    ) -> CGFloat {
        guard minutes > 0 else { return minGap }
        let linear = CGFloat(minutes) * ppm
        let compressed = CGFloat(log(1 + minutes / refMin)) * ppm * CGFloat(refMin)
        let width = min(linear, compressed)
        return min(max(width, minGap), maxGap)
    }

    func x(for time: Date) -> CGFloat {
        guard anchors.count >= 2 else { return 0 }

        if time <= anchors.first!.time {
            let dist = anchors.first!.time.timeIntervalSince(time) / 60
            return anchors.first!.x - CGFloat(dist) * TimeSliderMetrics.pointsPerMinute
        }

        if time >= anchors.last!.time {
            let dist = time.timeIntervalSince(anchors.last!.time) / 60
            return anchors.last!.x + CGFloat(dist) * TimeSliderMetrics.pointsPerMinute
        }

        for i in 0..<anchors.count - 1 {
            let a = anchors[i]
            let b = anchors[i + 1]
            if time >= a.time && time <= b.time {
                let totalSec = b.time.timeIntervalSince(a.time)
                guard totalSec > 0 else { return a.x }
                let fraction = CGFloat(time.timeIntervalSince(a.time) / totalSec)
                return a.x + fraction * (b.x - a.x)
            }
        }

        return 0
    }

    func time(for x: CGFloat, fallback: Date) -> Date {
        guard anchors.count >= 2 else { return fallback }

        if x <= anchors.first!.x {
            let dist = anchors.first!.x - x
            let minutes = Double(dist / TimeSliderMetrics.pointsPerMinute)
            return anchors.first!.time.addingTimeInterval(-minutes * 60)
        }

        if x >= anchors.last!.x {
            let dist = x - anchors.last!.x
            let minutes = Double(dist / TimeSliderMetrics.pointsPerMinute)
            return anchors.last!.time.addingTimeInterval(minutes * 60)
        }

        for i in 0..<anchors.count - 1 {
            let a = anchors[i]
            let b = anchors[i + 1]
            if x >= a.x && x <= b.x {
                let totalX = b.x - a.x
                guard totalX > 0 else { return a.time }
                let fraction = Double((x - a.x) / totalX)
                let totalSec = b.time.timeIntervalSince(a.time)
                return a.time.addingTimeInterval(fraction * totalSec)
            }
        }

        return fallback
    }
}

struct TimeSliderLane: Equatable {
    let lane: Int
    let count: Int
}
