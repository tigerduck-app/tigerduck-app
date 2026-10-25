import Foundation

/// The Add Course sheet's search and filters. Each request's courses show as soon as it
/// answers, and the filter page's option lists come from the device first.
@Observable
final class CourseSearchModel {
    typealias Search = @Sendable (CourseSearchRequest) async throws -> [CourseSearchResult]
    typealias FetchOptions = @Sendable () async throws -> CourseSearchOptions

    var filters = CourseSearchFilters()
    /// Rows per request language, none repeated. A language that found nothing has no entry.
    private(set) var results: [String: [CourseSearchResult]] = [:]
    private(set) var isSearching = false
    private(set) var hasSearched = false
    private(set) var failure: (any Error)?
    private(set) var options = CourseSearchOptions()

    @ObservationIgnored private let search: Search
    @ObservationIgnored private let fetchOptions: FetchOptions
    @ObservationIgnored private let cache: DataCache
    @ObservationIgnored private var hasStoredOptions = false
    @ObservationIgnored private var hasFreshOptions = false

    init(
        cache: DataCache = .shared,
        search: @escaping Search = CourseLookupService.search,
        fetchOptions: @escaping FetchOptions = CourseLookupService.fetchSearchOptions
    ) {
        self.cache = cache
        self.search = search
        self.fetchOptions = fetchOptions
    }

    /// Waits `delay`, then searches. The previous query's rows go at once and the search shows as
    /// running, so no old row can be tapped and no "not found" shows while the new query waits.
    /// A blank query only clears, since a request with every search field empty never returns.
    func search(_ query: String, semester: String, after delay: Duration = .zero) async {
        let query = query.trimmingCharacters(in: .whitespaces)
        results = [:]
        failure = nil
        hasSearched = !query.isEmpty
        isSearching = !query.isEmpty
        guard !query.isEmpty else { return }
        if delay > .zero {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
        }
        for round in CourseSearch.rounds(for: query, semester: semester, filters: filters) {
            let allFailed = await run(round)
            guard !Task.isCancelled else { return }
            if allFailed || !results.isEmpty { break }
        }
        isSearching = false
    }

    /// Adds each request's rows as it answers. True when every request in the round failed.
    private func run(_ requests: [CourseSearchRequest]) async -> Bool {
        let search = search
        var answered = false
        var firstError: (any Error)?
        await withTaskGroup(of: (String, Result<[CourseSearchResult], any Error>).self) { group in
            for request in requests {
                let language = request.Language
                group.addTask {
                    do {
                        return (language, .success(try await search(request)))
                    } catch {
                        return (language, .failure(error))
                    }
                }
            }
            for await (language, result) in group where !Task.isCancelled {
                switch result {
                case .success(let rows):
                    answered = true
                    guard !rows.isEmpty else { continue }
                    results[language] = CourseSearch.merge(results[language] ?? [], rows)
                case .failure(let error):
                    firstError = firstError ?? error
                }
            }
        }
        guard !answered, let firstError, !Task.isCancelled else { return false }
        failure = firstError
        AppLogger.captureError(firstError, context: ["feature": "addCourseSheet.search"])
        return true
    }

    /// The row to add a course from, in the app's course language. A course only the other
    /// language found is looked up once by its number; nil when that fails or finds nothing,
    /// and the caller then keeps the row it was found with.
    func appLanguageRow(of courseNo: String, language: String, semester: String) async -> CourseSearchResult? {
        if let row = results[language]?.first(where: { $0.CourseNo == courseNo }) { return row }
        do {
            return try await search(.forCourseNo(courseNo, semester: semester, language: language))
                .first { $0.CourseNo == courseNo }
        } catch {
            AppLogger.captureError(error, context: ["feature": "addCourseSheet.appLanguageRow"])
            return nil
        }
    }

    /// Shows the stored lists at once, then fetches the school's once per sheet. A failed or empty
    /// fetch keeps the stored lists, and the next call tries again.
    func refreshOptions() async {
        if !hasStoredOptions {
            hasStoredOptions = true
            options = cache.loadCourseSearchOptions() ?? options
        }
        guard !hasFreshOptions else { return }
        hasFreshOptions = true
        do {
            let fresh = try await fetchOptions()
            guard !fresh.colleges.isEmpty, !fresh.dimensions.isEmpty else {
                hasFreshOptions = false
                return
            }
            options = fresh
            cache.saveCourseSearchOptions(fresh)
        } catch {
            hasFreshOptions = false
            if !Task.isCancelled {
                AppLogger.captureError(error, context: ["feature": "addCourseSheet.options"])
            }
        }
    }
}
