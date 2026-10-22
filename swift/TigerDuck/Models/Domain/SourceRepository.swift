import Foundation

struct SourceRepository: Identifiable, Hashable {
    let slug: String
    let descriptionKey: String
    let url: URL
    let isCurrent: Bool

    var id: String { slug }

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
