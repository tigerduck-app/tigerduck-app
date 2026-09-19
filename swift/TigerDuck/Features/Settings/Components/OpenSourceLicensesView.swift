import MarkdownUI
import SwiftUI

/// `licenses.json`: TigerDuck's own licence and every Swift package the app
/// links, each package's licence file verbatim. Written by
/// `tools/generate_licenses.py`; CI fails when it falls behind
/// `Package.resolved`.
struct LicenseCatalog: Decodable {
    struct AppLicense: Decodable {
        let license: String
        let text: String
    }

    struct Package: Decodable, Identifiable, Hashable {
        struct LicenseText: Decodable, Hashable {
            /// The file it was read from: `LICENSE`, `COPYING`, `THIRD_PARTY_NOTICES.md`, ...
            let file: String
            let text: String
        }

        let identity: String
        let name: String
        let version: String?
        let url: URL?
        /// SPDX expression, e.g. `MIT` or `BSD-2-Clause AND MIT`.
        let license: String
        /// The copyright lines of the licence file, as the holder wrote them.
        let copyright: [String]
        let texts: [LicenseText]

        var id: String { identity }
    }

    let app: AppLicense
    let packages: [Package]

    static func load(from bundle: Bundle = .main) -> LicenseCatalog? {
        guard let url = bundle.url(forResource: "licenses", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LicenseCatalog.self, from: data)
    }

    /// Read once: both licence pages use it and it does not change at run time.
    static let bundled = load()

    /// Licence files are hard-wrapped at ~72 columns, which on a phone breaks
    /// every line a second time. Joins the lines of each paragraph so the
    /// text wraps to the screen, keeping blank lines between paragraphs and
    /// list items — `(a)`, `1.`, `-` — on lines of their own. Only whitespace
    /// changes; every word stays as written. Android does the same.
    static func reflow(_ text: String) -> String {
        let listItem = /^([-*•]|\(?[0-9a-zA-Z]{1,3}[.)])\s/
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: /\n\s*\n/)
            .map { paragraph in
                paragraph
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .reduce(into: [String]()) { lines, line in
                        if lines.isEmpty || line.firstMatch(of: listItem) != nil {
                            lines.append(line)
                        } else {
                            lines[lines.count - 1] += " " + line
                        }
                    }
                    .joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }
}

/// Sub-page behind Open-source licences on `AboutOthersView`: TigerDuck's own
/// licence, then every Swift package the app links. Android has the same
/// page, fed by its own build's dependency list.
struct OpenSourceLicensesView: View {
    private let catalog = LicenseCatalog.bundled

    var body: some View {
        List {
            if let catalog {
                Section {
                    NavigationLink {
                        AppLicenseView(license: catalog.app)
                    } label: {
                        licenseRow(title: String(localized: "app_name"), subtitle: catalog.app.license)
                    }
                }
                Section(String(localized: "settings_licenses_section_third_party")) {
                    ForEach(catalog.packages) { package in
                        NavigationLink {
                            PackageLicenseView(package: package)
                        } label: {
                            licenseRow(title: package.name, subtitle: package.license)
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "settings_open_source_licenses"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func licenseRow(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// TigerDuck's own licence in full, with the way to its source that the
/// AGPL is about.
private struct AppLicenseView: View {
    let license: LicenseCatalog.AppLicense

    var body: some View {
        List {
            if let repository = SourceRepository.all.first(where: \.isCurrent) {
                Section {
                    LicenseLinkRow(titleKey: "settings_view_source_code", url: repository.url)
                }
            }
            Section(license.license) {
                LicenseTextView(file: "LICENSE", text: license.text)
            }
        }
        .navigationTitle(String(localized: "app_name"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One package: who holds the copyright, where it lives, and every licence
/// and notice file it ships, verbatim.
private struct PackageLicenseView: View {
    let package: LicenseCatalog.Package

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    if let version = package.version {
                        Text(version)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(package.copyright, id: \.self) { line in
                        Text(line)
                            .font(.callout)
                    }
                }
                if let url = package.url {
                    LicenseLinkRow(titleKey: "settings_licenses_website", url: url)
                }
            }
            ForEach(package.texts, id: \.file) { file in
                Section(file.file) {
                    LicenseTextView(file: file.file, text: file.text)
                }
            }
        }
        .navigationTitle(package.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A licence or notice file. Markdown ones (sentry-cocoa's
/// `THIRD_PARTY_NOTICES.md`) are rendered, since their headings and code
/// fences are how they separate one notice from the next; plain text is
/// reflowed to the screen.
private struct LicenseTextView: View {
    let file: String
    let text: String

    var body: some View {
        if file.lowercased().hasSuffix(".md") {
            Markdown(text)
                .markdownTextStyle { FontSize(.em(0.85)) }
                .textSelection(.enabled)
        } else {
            Text(LicenseCatalog.reflow(text))
                .font(.footnote)
                .textSelection(.enabled)
        }
    }
}

/// A row that leaves the app for `url`, honouring the in-app / external
/// browser preference and drawn like the other links out of Settings.
private struct LicenseLinkRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var showInApp = false

    let titleKey: String.LocalizationValue
    let url: URL

    var body: some View {
        Button {
            if appState.browserPreference == .inApp {
                showInApp = true
            } else {
                openURL(url)
            }
        } label: {
            HStack {
                Text(String(localized: titleKey))
                    .foregroundStyle(.tint)
                Spacer()
                Image(systemName: appState.browserPreference == .inApp
                      ? "rectangle.portrait.and.arrow.right"
                      : "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showInApp) {
            InAppBrowserView(url: url)
                .ignoresSafeArea()
        }
    }
}
