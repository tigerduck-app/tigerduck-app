import Foundation

/// A public TigerDuck repository, as listed by the iPhone's source-code
/// picker and the Mac's About tab.
///
/// Shared rather than declared once per platform because it is the same
/// list: a repository added, renamed or retired would otherwise have to be
/// remembered in two places, and the copy nobody opened that week is the
/// one that goes stale.
struct SourceRepository: Identifiable, Hashable {
    /// GitHub repository name. Shown verbatim — never localized.
    let slug: String
    /// Localization key for the one-line description under the slug.
    let descriptionKey: String
    let url: URL
    /// The repository this build was compiled from.
    let isCurrent: Bool

    var id: String { slug }

    /// The organization page. Listed above the repositories rather than
    /// among them — it is where they all live, not one of them.
    static let organization = SourceRepository(
        slug: "tigerduck-app",
        descriptionKey: "source_code_picker_org_description",
        url: URL(string: "https://github.com/tigerduck-app")!,
        isCurrent: false
    )

    static let all: [SourceRepository] = [
        SourceRepository(
            slug: "tigerduck-app",
            descriptionKey: "source_code_picker_repo_apple_description",
            url: URL(string: "https://github.com/tigerduck-app/tigerduck-app")!,
            isCurrent: true
        ),
        SourceRepository(
            slug: "tigerduck-app-android",
            descriptionKey: "source_code_picker_repo_android_description",
            url: URL(string: "https://github.com/tigerduck-app/tigerduck-app-android")!,
            isCurrent: false
        ),
        SourceRepository(
            slug: "app-translation",
            descriptionKey: "source_code_picker_repo_translation_description",
            url: URL(string: "https://github.com/tigerduck-app/app-translation")!,
            isCurrent: false
        ),
        SourceRepository(
            slug: "name-abbr",
            descriptionKey: "source_code_picker_repo_name_abbr_description",
            url: URL(string: "https://github.com/tigerduck-app/name-abbr")!,
            isCurrent: false
        ),
        SourceRepository(
            slug: "tigerduck-web",
            descriptionKey: "source_code_picker_repo_web_description",
            url: URL(string: "https://github.com/tigerduck-app/tigerduck-web")!,
            isCurrent: false
        ),
    ]
}
