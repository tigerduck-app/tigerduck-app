import Foundation
import Observation

@Observable
@MainActor
final class EmptyClassroomLoader {
    struct Reader {
        let credentials: ClassroomUsageService.Credentials
    }

    struct Read: Equatable {
        let usage: CampusUsage
        let readAt: Date
    }

    private(set) var siteStatus = ServerStatus.unknown
    private(set) var isReading = false

    @ObservationIgnored var reader: @MainActor () -> Reader? = { nil }
    @ObservationIgnored private let service: ClassroomUsageService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var running: (day: Date, id: Int)?
    @ObservationIgnored private var reads = 0

    init(service: ClassroomUsageService? = nil) {
        self.service = service ?? .shared
    }

    func isReading(_ day: Date) -> Bool {
        running?.day == day
    }

    func stop() {
        task?.cancel()
        task = nil
        running = nil
        isReading = false
    }

    func noteSiteStatus() {
        siteStatus = service.siteStatus
    }

    /// The rooms an earlier read of `day` kept, while they are fresh.
    func kept(on day: Date) -> Read? {
        service.keptUsage(on: day).map { Read(usage: $0.usage, readAt: $0.fetchedAt) }
    }

    /// Reads `day` for the reader a caller got from `reader`. `finish` gets the outcome unless
    /// a newer read or a sign-out replaced this one, and `isWanted` says whether the screen
    /// still shows the day.
    func read(
        _ day: Date, isToday: Bool, force: Bool, by reader: Reader,
        isWanted: @escaping @MainActor () -> Bool,
        finish: @escaping @MainActor (Result<Read, any Error>) -> Void
    ) {
        reads &+= 1
        let id = reads
        running = (day, id)
        isReading = true
        task = Task { [weak self, service] in
            let outcome: Result<Read, any Error>
            do {
                let kept = try await service.usage(on: day, isToday: isToday, force: force, credentials: reader.credentials)
                outcome = .success(Read(usage: kept.usage, readAt: kept.fetchedAt))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            if running?.id == id {
                running = nil
                isReading = false
            }
            siteStatus = service.siteStatus
            guard !Task.isCancelled, isWanted(), reader.credentials.signIn.isCurrent else { return }
            finish(outcome)
        }
    }

    func wait() async {
        await task?.value
    }
}
