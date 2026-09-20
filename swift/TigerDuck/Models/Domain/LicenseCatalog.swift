import Foundation

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
