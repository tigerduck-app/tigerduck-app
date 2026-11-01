import Foundation

nonisolated struct RequestChain {
    private var last: Task<Void, Error>?

    mutating func append(_ request: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
        let previous = last
        let task = Task {
            _ = try? await previous?.value
            try await request()
        }
        last = task
        return task
    }

    mutating func finished(_ task: Task<Void, Error>) {
        if last == task { last = nil }
    }
}
