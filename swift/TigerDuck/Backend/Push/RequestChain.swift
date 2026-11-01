import Foundation

nonisolated struct RequestChain {
    private var last: Task<Void, Error>?
    private(set) var inLine = 0

    mutating func append(_ request: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
        let previous = last
        let task = Task {
            _ = try? await previous?.value
            try await request()
        }
        last = task
        inLine += 1
        return task
    }

    mutating func finished(_ task: Task<Void, Error>) {
        inLine -= 1
        if last == task { last = nil }
    }
}
