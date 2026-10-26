import Foundation

/// The Add Course sheet's search and filters, over the term's catalog from the TigerDuck
/// backend. The stored catalog is searched at once, and the backend is asked once per sheet
/// whether it changed.
@Observable
final class CourseSearchModel {
    typealias FetchCatalog = @Sendable (_ semester: String, _ language: String, _ etag: String?) async throws
        -> CourseCatalogClient.Answer

    var filters = CourseSearchFilters()
    /// Rows per catalog language, none repeated. A language that found nothing has no entry.
    private(set) var results: [String: [CourseSearchResult]] = [:]
    private(set) var isSearching = false
    private(set) var hasSearched = false
    private(set) var failure: (any Error)?
    private(set) var options = CourseSearchOptions()
    /// Moves when the sheet must search again for the same query and filters: the catalog
    /// changed, or Enter retries a failed search.
    private(set) var revision = 0

    @ObservationIgnored private let cache: DataCache
    @ObservationIgnored private var catalogs: [String: CourseCatalog] = [:]
    @ObservationIgnored private var storedETags: [String: String] = [:]
    @ObservationIgnored private var storedRead: Task<Void, Never>?
    @ObservationIgnored private var revalidation: Task<Void, Never>?
    @ObservationIgnored private var catalogFailure: (any Error)?
    @ObservationIgnored private var lacksLanguage = false

    init(cache: DataCache = .shared) {
        self.cache = cache
    }

    /// Searches the catalog, once it is loaded, off the main thread. A blank query only clears.
    func search(_ query: String, semester: String, fetch: @escaping FetchCatalog) async {
        let query = query.trimmingCharacters(in: .whitespaces)
        hasSearched = !query.isEmpty
        if query.isEmpty { results = [:] }
        if catalogs.isEmpty {
            failure = nil
            isSearching = !query.isEmpty
        }
        await loadCatalog(semester: semester, fetch: fetch)
        guard !Task.isCancelled else { return }
        guard !query.isEmpty else {
            failure = nil
            isSearching = false
            return
        }
        guard !catalogs.isEmpty else {
            results = [:]
            failure = catalogFailure ?? CourseCatalogError.unavailable
            isSearching = false
            return
        }
        let courses = catalogs.mapValues(\.courses)
        let filters = filters
        let found = await Task.detached { CourseSearch.search(query, in: courses, filters: filters) }.value
        guard !Task.isCancelled else { return }
        results = found
        failure = nil
        isSearching = false
    }

    /// Enter in the search field. It searches again only to retry a failed search or a catalog
    /// language that failed to load, as one that ran or is running would find the same rows.
    func submit() {
        guard failure != nil || lacksLanguage else { return }
        lacksLanguage = false
        revalidation = nil
        revision &+= 1
    }

    /// The row to add a course from, in the app's course language; nil when that language's
    /// catalog lacks it, and the caller then keeps the row it was found with.
    func appLanguageRow(of courseNo: String, language: String) -> CourseSearchResult? {
        catalogs[language]?.courses.first { $0.row.CourseNo == courseNo }?.row
    }

    /// Reads the stored catalog, then asks the backend once whether it changed. Waits for the
    /// backend only while no catalog is stored.
    private func loadCatalog(semester: String, fetch: @escaping FetchCatalog) async {
        if storedRead == nil {
            storedRead = Task { await readStored(semester) }
        }
        await storedRead?.value
        if revalidation == nil {
            revalidation = Task { await revalidate(semester, fetch) }
        }
        if catalogs.isEmpty { await revalidation?.value }
    }

    private func readStored(_ semester: String) async {
        let (cache, languages) = (cache, CourseSearch.languages)
        let stored = await Task.detached {
            var stored: [String: (catalog: CourseCatalog, etag: String?)] = [:]
            for language in languages {
                guard let copy = cache.loadCourseCatalog(semester: semester, language: language) else { continue }
                do {
                    stored[language] = (try JSONDecoder().decode(CourseCatalog.self, from: copy.body), copy.etag)
                } catch {
                    AppLogger.captureError(error, context: ["feature": "addCourseSheet.storedCatalog"])
                }
            }
            return stored
        }.value
        guard !stored.isEmpty else { return }
        catalogs = stored.mapValues(\.catalog)
        storedETags = stored.compactMapValues(\.etag)
        options = CourseSearch.options(catalogs)
    }

    private func revalidate(_ semester: String, _ fetch: @escaping FetchCatalog) async {
        let cache = cache
        let hadCatalog = !catalogs.isEmpty
        var firstError: (any Error)?
        var changed = false
        await withTaskGroup(of: (String, Result<CourseCatalog?, any Error>).self) { group in
            for language in CourseSearch.languages {
                let etag = storedETags[language]
                group.addTask {
                    do {
                        // Awaited before the tuple is built: in optimized builds (Swift 6.4) an inline
                        // `try await` in the returned tuple leaves `language` unset.
                        let answer = try await fetch(semester, language, etag)
                        guard case .changed(let copy) = answer else { return (language, .success(nil)) }
                        let catalog = try JSONDecoder().decode(CourseCatalog.self, from: copy.body)
                        cache.saveCourseCatalog(copy, semester: semester, language: language)
                        return (language, .success(catalog))
                    } catch {
                        return (language, .failure(error))
                    }
                }
            }
            for await (language, result) in group {
                switch result {
                case .success(let catalog?):
                    catalogs[language] = catalog
                    changed = true
                case .success(nil):
                    break
                case .failure(let error):
                    firstError = firstError ?? error
                    AppLogger.captureError(error, context: ["feature": "addCourseSheet.catalog"])
                }
            }
        }
        if changed {
            options = CourseSearch.options(catalogs)
            // A search that ran on the stored catalog runs again; one that waited goes on by itself.
            if hadCatalog { revision &+= 1 }
        }
        if catalogs.isEmpty { catalogFailure = firstError }
        lacksLanguage = catalogs.count < CourseSearch.languages.count
    }
}
