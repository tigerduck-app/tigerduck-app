import MarkdownUI
import SwiftUI

/// Sub-page behind Open-source licences on `AboutOthersView`: TigerDuck's own
/// licence and anything else it publishes, then every Swift package the app
/// links. Android has the same page, fed by its own build's dependency list.
struct OpenSourceLicensesView: View {
    private let catalog = LicenseCatalog.bundled

    var body: some View {
        List {
            if let catalog {
                // TigerDuck's own licence, and next to it anything TigerDuck
                // publishes separately — name-abbr is MIT, not the app's
                // AGPL, and listing it under "third-party" would be wrong.
                Section {
                    NavigationLink {
                        AppLicenseView(license: catalog.app)
                    } label: {
                        licenseRow(title: String(localized: "app_name"), subtitle: catalog.app.license)
                    }
                    ForEach(catalog.firstParty) { package in
                        NavigationLink {
                            PackageLicenseView(package: package)
                        } label: {
                            licenseRow(title: package.name, subtitle: package.license)
                        }
                    }
                }
                Section(String(localized: "settings_licenses_section_third_party")) {
                    ForEach(catalog.thirdParty) { package in
                        NavigationLink {
                            PackageLicenseView(package: package)
                        } label: {
                            licenseRow(title: package.name, subtitle: package.license)
                        }
                    }
                }
            } else {
                // The list did not load — `LicenseCatalog.load` has already
                // told Sentry why. What is left to do here is not leave an
                // empty page behind: the attribution MIT and BSD ask for,
                // and the offer of source the AGPL makes, are owed whether
                // or not a JSON file parsed, and the repository carries
                // both.
                Section {
                    Text(String(localized: "settings_licenses_unavailable"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let url = LicenseCatalog.fallbackLicenseURL {
                        LicenseLinkRow(titleKey: "settings_open_source_licenses", url: url)
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

/// One package: why it ships when that isn't obvious, who holds the
/// copyright, where it lives, and every licence and notice file it ships,
/// verbatim.
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
                    if let note = package.note {
                        Text(note)
                            .font(.callout)
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
