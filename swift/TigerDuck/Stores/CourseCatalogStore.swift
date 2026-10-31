import Foundation

/// The term's course catalog from the TigerDuck backend, in each course language: the stored copy
/// first, then the backend asked once whether it changed. The Add Course sheet searches it.
@Observable
final class CourseCatalogStore {
    typealias Catalog = CourseCatalog
    typealias Row = CourseSearchResult
    typealias Options = CourseSearchOptions
    typealias Files = CourseCatalogFiles
    typealias Failure = CourseCatalogError
    typealias Fetch = @Sendable (_ semester: String, _ language: String, _ etag: String?) async throws
        -> CourseCatalogClient.Answer

    static let languages = ["zh", "en"]

    private(set) var options = CourseSearchOptions()
    /// Moves when a newer catalog replaces one a search already ran on.
    private(set) var revision = 0
    @ObservationIgnored private(set) var catalogs: [String: CourseCatalog] = [:]
    /// Why no catalog loaded, while none did.
    @ObservationIgnored private(set) var loadFailure: (any Error)?
    @ObservationIgnored private(set) var lacksLanguage = false
    @ObservationIgnored private let files: CourseCatalogFiles
    @ObservationIgnored private var storedETags: [String: String] = [:]
    @ObservationIgnored private var storedRead: Task<Void, Never>?
    @ObservationIgnored private var revalidation: Task<Void, Never>?

    init(files: CourseCatalogFiles = CourseCatalogFiles()) {
        self.files = files
    }

    /// Asks the backend for the catalog with the account's sign-in.
    static func fetch(auth: BackendAuth) -> Fetch {
        let client = CourseCatalogClient(backend: BackendClient(session: BackendClient.catalogSession, auth: auth))
        return { @MainActor in try await client.fetch(semester: $0, language: $1, etag: $2) }
    }

    /// Lets the next load ask the backend again, for a language that failed.
    func retry() {
        lacksLanguage = false
        revalidation = nil
    }

    /// Reads the stored catalog, then asks the backend once whether it changed. Waits for the
    /// backend only while no catalog is stored.
    func load(semester: String, fetch: @escaping Fetch) async {
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
        let (cache, languages) = (files, Self.languages)
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
        options = Self.options(catalogs)
    }

    private func revalidate(_ semester: String, _ fetch: @escaping Fetch) async {
        let cache = files
        let hadCatalog = !catalogs.isEmpty
        var firstError: (any Error)?
        var fresh: [String: (catalog: CourseCatalog, etag: String?)] = [:]
        await withTaskGroup(of: (String, Result<(CourseCatalog, String?)?, any Error>).self) { group in
            for language in Self.languages {
                let etag = storedETags[language]
                group.addTask {
                    do {
                        // Awaited before the tuple is built: in optimized builds (Swift 6.4) an inline
                        // `try await` in the returned tuple leaves `language` unset.
                        let answer = try await fetch(semester, language, etag)
                        guard case .changed(let copy) = answer else { return (language, .success(nil)) }
                        let catalog = try JSONDecoder().decode(CourseCatalog.self, from: copy.body)
                        cache.saveCourseCatalog(copy, semester: semester, language: language)
                        return (language, .success((catalog, copy.etag)))
                    } catch {
                        return (language, .failure(error))
                    }
                }
            }
            for await (language, result) in group {
                switch result {
                case .success(let (catalog, etag)?):
                    fresh[language] = (catalog, etag)
                case .success(nil):
                    break
                case .failure(let error):
                    firstError = firstError ?? error
                    AppLogger.captureError(error, context: ["feature": "addCourseSheet.catalog"])
                }
            }
        }
        // All at once, so no search runs on one language while the other is still on its way.
        for (language, copy) in fresh {
            catalogs[language] = copy.catalog
            storedETags[language] = copy.etag
        }
        if !fresh.isEmpty {
            options = Self.options(catalogs)
            // A search that ran on the stored catalog runs again; one that waited goes on by itself.
            if hadCatalog { revision &+= 1 }
        }
        if catalogs.isEmpty { loadFailure = firstError }
        lacksLanguage = catalogs.count < Self.languages.count
    }

    /// The filter lists of the term, with each name in both languages. A list only one language
    /// has keeps that language's names for both.
    static func options(_ catalogs: [String: CourseCatalog]) -> CourseSearchOptions {
        guard let zh = catalogs["zh"] ?? catalogs["en"] else { return CourseSearchOptions() }
        let en = catalogs["en"] ?? zh
        func list(_ named: [CourseCatalog.Named], english: [CourseCatalog.Named]) -> [CourseSearchOptions.Option] {
            let english = Dictionary(english.map { ($0.no, $0.name) }, uniquingKeysWith: { first, _ in first })
            return named.map { .init(code: $0.no, name: $0.name, englishName: english[$0.no] ?? $0.name) }
        }
        let enColleges = Dictionary(en.colleges.map { ($0.no, $0) }, uniquingKeysWith: { first, _ in first })
        return CourseSearchOptions(
            colleges: zh.colleges.map { college in
                CourseSearchOptions.College(
                    name: college.name,
                    englishName: enColleges[college.no]?.name ?? college.name,
                    departments: list(college.departments, english: enColleges[college.no]?.departments ?? [])
                )
            },
            dimensions: list(zh.dimensions, english: en.dimensions)
        )
    }
}
