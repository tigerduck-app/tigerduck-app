#if os(iOS)
import Foundation

enum SchoolMailFixtures {
    private final class Token {}

    enum FixtureError: Error { case missing(String) }

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle(for: Token.self).url(forResource: name, withExtension: "json") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    static func lines(_ name: String) throws -> [String] {
        guard let url = Bundle(for: Token.self).url(forResource: name, withExtension: "txt") else {
            throw FixtureError.missing(name)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func rawEML(_ name: String) throws -> Data {
        guard let url = Bundle(for: Token.self).url(forResource: name, withExtension: "eml") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }
}
#endif
