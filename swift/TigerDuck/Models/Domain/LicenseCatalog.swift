import Foundation

/// `licenses.json`: TigerDuck's own licence, every Swift package the app
/// links, and anything else that ships inside the bundle under a licence of
/// its own — each with its licence file verbatim. Written by
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
        /// Why this ships, for material the dependency graph doesn't explain.
        let note: String?
        /// TigerDuck's own, published separately: listed beside the app, not under third parties.
        let firstParty: Bool?
        let texts: [LicenseText]

        var id: String { identity }
    }

    let app: AppLicense
    let packages: [Package]

    /// TigerDuck's own, shown beside the app's licence.
    var firstParty: [Package] { packages.filter { $0.firstParty == true } }
    /// Everything else, which is genuinely someone else's work.
    var thirdParty: [Package] { packages.filter { $0.firstParty != true } }

    /// The one way of coming back empty that arrives without an error of
    /// its own to report. The app's other bundled JSON is allowed to fail
    /// quietly — nobody is worse off for a What's New sheet that doesn't
    /// open — but this page is how the MIT and BSD notices travel and how
    /// the AGPL's offer of source is made, so a blank one is something we
    /// hear about rather than read about in a report.
    private enum LoadFailure: Error {
        /// `licenses.json` never reached the bundle: dropped from the
        /// target's resources rather than written wrong.
        case resourceMissing
    }

    static func load(from bundle: Bundle = .main) -> LicenseCatalog? {
        guard let url = bundle.url(forResource: "licenses", withExtension: "json") else {
            AppLogger.captureError(
                LoadFailure.resourceMissing,
                context: ["phase": "licenseCatalog.resource"]
            )
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            AppLogger.captureError(error, context: ["phase": "licenseCatalog.read"])
            return nil
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            // Decoding is all or nothing: one entry the generator wrote
            // wrong takes TigerDuck's own AGPL text down with every
            // package. The error names the key path that failed, which is
            // the one thing a blank page in the field cannot tell us.
            AppLogger.captureError(error, context: ["phase": "licenseCatalog.decode"])
            return nil
        }
    }

    /// Read once: both licence pages use it and it does not change at run time.
    static let bundled = load()

    /// Where the licence still is when the bundled list is not: the
    /// `LICENSE` of the repository this build was compiled from. Read off
    /// ``SourceRepository`` rather than written out a second time, so a
    /// rename carries — and kept here rather than in ``AppURLs`` because
    /// the fallback on the two licence pages is the only thing that wants
    /// it.
    static let fallbackLicenseURL: URL? = SourceRepository.all
        .first(where: \.isCurrent)?
        .url
        .appending(path: "blob/main/LICENSE")

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
