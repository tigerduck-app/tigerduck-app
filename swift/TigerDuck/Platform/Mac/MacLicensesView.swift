#if os(macOS)
import MarkdownUI
import SwiftUI

/// The licences window, opened from the About tab's Open-source licences
/// row. A window of its own rather than a page inside Settings: that window
/// is fixed at 580×480 with no navigation stack to push onto, and a licence
/// runs to thousands of words. The list on the left is the same one the
/// iPhone shows on `OpenSourceLicensesView`.
struct MacLicensesView: View {
    /// The window's scene id, shared with `TigerDuckApp`'s `openWindow`.
    static let windowID = "licenses"

    @Environment(\.openURL) private var openURL
    @State private var selection: Selection? = .app

    private let catalog = LicenseCatalog.bundled

    private enum Selection: Hashable {
        case app
        case package(String)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if let catalog {
                    Section {
                        row(title: String(localized: "app_name"), subtitle: catalog.app.license)
                            .tag(Selection.app)
                    }
                    Section(String(localized: "settings_licenses_section_third_party")) {
                        ForEach(catalog.packages) { package in
                            row(title: package.name, subtitle: package.license)
                                .tag(Selection.package(package.id))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selection {
                    case .app, nil:
                        if let app = catalog?.app { appDetail(app) }
                    case .package(let id):
                        if let package = catalog?.packages.first(where: { $0.id == id }) {
                            packageDetail(package)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            // Each licence scrolls from its own top, rather than keeping the
            // offset of the one before it.
            .id(selection)
        }
        .navigationTitle(String(localized: "settings_open_source_licenses"))
    }

    private func row(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func appDetail(_ app: LicenseCatalog.AppLicense) -> some View {
        heading(String(localized: "app_name"), subtitle: app.license)
        if let repository = SourceRepository.all.first(where: \.isCurrent) {
            linkRow("settings_view_source_code", url: repository.url)
        }
        licenseText(file: "LICENSE", text: app.text)
    }

    @ViewBuilder
    private func packageDetail(_ package: LicenseCatalog.Package) -> some View {
        heading(package.name, subtitle: [package.version, package.license].compactMap { $0 }.joined(separator: " · "))
        if let note = package.note {
            Text(note)
                .font(.callout)
                .textSelection(.enabled)
        }
        ForEach(package.copyright, id: \.self) { line in
            Text(line)
                .font(.callout)
                .textSelection(.enabled)
        }
        if let url = package.url {
            linkRow("settings_licenses_website", url: url)
        }
        ForEach(package.texts, id: \.file) { file in
            Text(file.file)
                .font(.headline)
                .padding(.top, 8)
            licenseText(file: file.file, text: file.text)
        }
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }

    /// Markdown notice files are rendered; plain text is reflowed to the
    /// window's width. Same split as the iPhone's page.
    @ViewBuilder
    private func licenseText(file: String, text: String) -> some View {
        if file.lowercased().hasSuffix(".md") {
            Markdown(text)
                .markdownTextStyle { FontSize(.em(0.9)) }
                .textSelection(.enabled)
        } else {
            Text(LicenseCatalog.reflow(text))
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    /// Every link here hands off to the default browser, as the About tab's
    /// do — the Mac has no in-app browser.
    private func linkRow(_ key: String.LocalizationValue, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 4) {
                Text(String(localized: key))
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
            }
            .foregroundStyle(.tint)
        }
        .buttonStyle(.link)
    }
}
#endif
