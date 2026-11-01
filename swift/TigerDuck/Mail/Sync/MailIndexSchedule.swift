#if os(iOS)
import Foundation

nonisolated struct MailIndexSchedule {
    private var completed: (at: Date, wipeCount: Int)?
    private var retryAt: Date?
    private var failedPasses = 0
    private(set) var arrivals = 0

    func notDueReason(now: Date, wipeCount: Int) -> String? {
        if isFresh(now: now, wipeCount: wipeCount) { return "fresh" }
        if let retryAt, now < retryAt {
            return "waiting for retry in \(Int(retryAt.timeIntervalSince(now).rounded(.up)))s"
        }
        return nil
    }

    private func isFresh(now: Date, wipeCount: Int) -> Bool {
        guard let completed, completed.wipeCount == wipeCount else { return false }
        return now.timeIntervalSince(completed.at) < MailConstants.indexResyncInterval
    }

    mutating func skipFreshness() {
        completed = nil
    }

    mutating func skipRetryWait() {
        retryAt = nil
    }

    mutating func noteNewMail() {
        arrivals += 1
        completed = nil
    }

    mutating func passFailed(now: Date) -> TimeInterval {
        failedPasses += 1
        let delay = MailConstants.indexRetryDelay * Double(1 << min(failedPasses - 1, 4))
        let retryIn = min(delay, MailConstants.indexResyncInterval)
        retryAt = now.addingTimeInterval(retryIn)
        return retryIn
    }

    mutating func passCompleted(now: Date, wipeCount: Int, arrivalsAtStart: Int) -> Bool {
        failedPasses = 0
        retryAt = nil
        guard arrivals == arrivalsAtStart else { return false }
        completed = (now, wipeCount)
        return true
    }

    mutating func reset() {
        completed = nil
        retryAt = nil
        failedPasses = 0
    }
}

nonisolated struct MailIndexStrikes {
    private struct MailKey: Hashable {
        var folder: String
        var uidValidity: UInt32
        var uid: UInt32
    }

    private static let failuresBeforeSkipping = 2

    private var strikes: [MailKey: Int] = [:]

    func skips(_ uid: UInt32, folder: String, uidValidity: UInt32) -> Bool {
        (strikes[MailKey(folder: folder, uidValidity: uidValidity, uid: uid)] ?? 0) >= Self.failuresBeforeSkipping
    }

    func batches(of missing: [UInt32], folder: String, uidValidity: UInt32) -> [[UInt32]] {
        var batches: [[UInt32]] = []
        var current: [UInt32] = []
        for uid in missing {
            if strikes[MailKey(folder: folder, uidValidity: uidValidity, uid: uid)] != nil {
                if !current.isEmpty { batches.append(current) }
                batches.append([uid])
                current = []
                continue
            }
            current.append(uid)
            if current.count == MailConstants.indexBatchSize {
                batches.append(current)
                current = []
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    mutating func strike(_ batch: [UInt32], folder: String, uidValidity: UInt32) {
        for uid in batch {
            let key = MailKey(folder: folder, uidValidity: uidValidity, uid: uid)
            strikes[key] = (strikes[key] ?? 0) + (batch.count == 1 ? 1 : 0)
        }
    }
}
#endif
