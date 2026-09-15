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

    /// Non-blank lines of a `.txt` fixture, in file order — mirrors the Android reader
    /// for the same corpus (`javaClass.getResourceAsStream(...).bufferedReader().readLines()
    /// .filter { it.isNotBlank() }`): lines that are empty or all whitespace are dropped,
    /// nothing else is special.
    static func lines(_ name: String) throws -> [String] {
        guard let url = Bundle(for: Token.self).url(forResource: name, withExtension: "txt") else {
            throw FixtureError.missing(name)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
#endif
