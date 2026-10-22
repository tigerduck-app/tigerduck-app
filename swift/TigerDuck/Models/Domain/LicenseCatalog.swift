import Foundation

struct LicenseCatalog: Decodable {
    struct AppLicense: Decodable {
        let license: String
        let text: String
    }

    struct Package: Decodable, Identifiable, Hashable {
        struct LicenseText: Decodable, Hashable {
            let file: String
            let text: String
        }

        let identity: String
        let name: String
        let version: String?
        let url: URL?
        let license: String
        let copyright: [String]
        let note: String?
        let firstParty: Bool?
        let texts: [LicenseText]

        var id: String { identity }
    }

    let app: AppLicense
    let packages: [Package]

    var firstParty: [Package] { packages.filter { $0.firstParty == true } }
    var thirdParty: [Package] { packages.filter { $0.firstParty != true } }

    private enum LoadFailure: Error {
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
            AppLogger.captureError(error, context: ["phase": "licenseCatalog.decode"])
            return nil
        }
    }

    static let bundled = load()

    static let fallbackLicenseURL: URL? = SourceRepository.all
        .first(where: \.isCurrent)?
        .url
        .appending(path: "blob/main/swift/TigerDuck/licenses.json")

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
