import Foundation

/// The Add Course sheet's search and filters, over the term's catalog from the TigerDuck
/// backend. The stored catalog is searched at once, and the backend is asked once per sheet
/// whether it changed.
@Observable
final class CourseSearchModel {
    typealias FetchCatalog = CourseCatalogStore.Fetch

    var filters = CourseSearchFilters()
    /// Rows per catalog language, none repeated. A language that found nothing has no entry.
    private(set) var results: [String: [CourseCatalogStore.Row]] = [:]
    private(set) var isSearching = false
    private(set) var hasSearched = false
    private(set) var failure: (any Error)?
    private var retries = 0
    private let catalog: CourseCatalogStore

    init(catalog files: CourseCatalogStore.Files = CourseCatalogStore.Files()) {
        catalog = CourseCatalogStore(files: files)
    }

    var options: CourseCatalogStore.Options { catalog.options }

    var searchAgainCount: Int { retries &+ catalog.revision }

    /// Searches the catalog, once it is loaded, off the main thread. A blank query only clears.
    func search(_ query: String, semester: String, fetch: @escaping FetchCatalog) async {
        let query = query.trimmingCharacters(in: .whitespaces)
        hasSearched = !query.isEmpty
        if query.isEmpty { results = [:] }
        if catalog.catalogs.isEmpty {
            failure = nil
            isSearching = !query.isEmpty
        }
        await catalog.load(semester: semester, fetch: fetch)
        guard !Task.isCancelled else { return }
        guard !query.isEmpty else {
            failure = nil
            isSearching = false
            return
        }
        guard !catalog.catalogs.isEmpty else {
            results = [:]
            failure = catalog.loadFailure ?? CourseCatalogStore.Failure.unavailable
            isSearching = false
            return
        }
        let courses = catalog.catalogs.mapValues(\.courses)
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
        guard failure != nil || catalog.lacksLanguage else { return }
        catalog.retry()
        retries &+= 1
    }

    /// The row to add a course from, in the app's course language; nil when that language's
    /// catalog lacks it, and the caller then keeps the row it was found with.
    func appLanguageRow(of courseNo: String, language: String) -> CourseCatalogStore.Row? {
        catalog.catalogs[language]?.courses.first { $0.row.CourseNo == courseNo }?.row
    }
}
