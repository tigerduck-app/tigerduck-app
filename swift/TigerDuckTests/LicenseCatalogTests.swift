import Foundation
import Testing

@testable import TigerDuck

/// The bundled `licenses.json` that Settings → Others → Open-source licences
/// reads, as `tools/generate_licenses.py` writes it.
@Suite("Open-source licences")
struct LicenseCatalogTests {

    @Test("the bundled list loads, TigerDuck's own licence first")
    func loads() throws {
        let catalog = try #require(LicenseCatalog.load())
        #expect(catalog.app.text.contains("GNU AFFERO GENERAL PUBLIC LICENSE"))
        #expect(!catalog.packages.isEmpty)
    }

    @Test("every package names its licence and carries the text")
    func everyPackageHasItsText() throws {
        let catalog = try #require(LicenseCatalog.load())
        for package in catalog.packages {
            #expect(!package.license.isEmpty, "\(package.name)")
            #expect(package.texts.contains { !$0.text.isEmpty }, "\(package.name)")
        }
    }

    @Test("reflow joins the hard-wrapped lines of a paragraph and keeps paragraphs apart")
    func reflowJoinsParagraphs() {
        #expect(
            LicenseCatalog.reflow(" Everyone is permitted to copy\n and distribute verbatim copies.\n\n                            Preamble\n")
                == "Everyone is permitted to copy and distribute verbatim copies.\n\nPreamble"
        )
    }

    @Test("reflow keeps each list item on a line of its own")
    func reflowKeepsListItems() {
        #expect(
            LicenseCatalog.reflow(
                "provided that:\n      (a) You must give\n          a copy; and\n      (b) You must cause\n          files\n- one\n* two\n2. Grant"
            ) == "provided that:\n(a) You must give a copy; and\n(b) You must cause files\n- one\n* two\n2. Grant"
        )
    }

    @Test("reflow reads Windows line endings")
    func reflowReadsCRLF() {
        #expect(LicenseCatalog.reflow("a\r\nb\r\n\r\nc") == "a b\n\nc")
    }

    @Test("Defaults' macro toolchain is not listed: nothing from it is linked")
    func buildOnlyPackagesAreLeftOut() throws {
        let catalog = try #require(LicenseCatalog.load())
        #expect(!catalog.packages.contains { $0.identity == "swift-syntax" })
    }

    /// The abbreviation tables ship as bundle resources, symlinked in from a
    /// submodule that is published under MIT. The app being AGPL says
    /// nothing about them, and MIT asks that its notice travel with the data.
    @Test("the abbreviation data is listed under its own licence, not the app's")
    func bundledDataIsListed() throws {
        let catalog = try #require(LicenseCatalog.load())
        let nameAbbr = try #require(catalog.packages.first { $0.identity == "name-abbr" })
        #expect(nameAbbr.license == "MIT")
        #expect(nameAbbr.copyright.contains { $0.contains("TigerDuck") })
        #expect(try #require(nameAbbr.texts.first).text.hasPrefix("MIT License"))
    }

    /// Scoped to what TigerDuck publishes itself, which is what the note
    /// is for: a Swift package's own metadata says where it came from and
    /// why it is linked, and a local package legitimately has neither a
    /// version nor a note for the generator to write.
    @Test("anything TigerDuck publishes itself says why it ships")
    func firstPartyEntriesExplainThemselves() throws {
        let catalog = try #require(LicenseCatalog.load())
        for package in catalog.firstParty {
            #expect(package.note?.isEmpty == false, "\(package.name) has no note")
        }
    }

    /// The split that decides whether a package is shown beside the app or
    /// under "Third-party libraries". Both pages read `firstParty` and
    /// `thirdParty`, never `packages`, so an entry that fell out of both —
    /// or landed in both — is a licence not shown, or shown twice under
    /// the wrong heading.
    @Test("TigerDuck's own is listed beside the app, never under third parties")
    func firstPartyIsNeverAThirdParty() throws {
        let catalog = try #require(LicenseCatalog.load())
        #expect(catalog.firstParty.contains { $0.identity == "name-abbr" })
        #expect(!catalog.thirdParty.contains { $0.identity == "name-abbr" })
    }

    @Test("the two lists share nothing and between them show every package")
    func partitionsCoverEveryPackage() throws {
        let catalog = try #require(LicenseCatalog.load())
        let firstParty = Set(catalog.firstParty.map(\.identity))
        let thirdParty = Set(catalog.thirdParty.map(\.identity))
        #expect(firstParty.isDisjoint(with: thirdParty))
        #expect(firstParty.union(thirdParty) == Set(catalog.packages.map(\.identity)))
        #expect(catalog.firstParty.count + catalog.thirdParty.count == catalog.packages.count)
    }

    // MARK: - When the list cannot be read

    /// Neither failure is expected of a shipped build — the resource is
    /// copied by the target, the JSON is generated and CI checks it — but
    /// this page is what carries the notices the app owes, so "returns
    /// nil, and the page says so" has to stay true rather than be assumed.
    /// The `bundle` parameter exists for these two.
    @Test("a bundle without the list loads to nil rather than trapping")
    func missingResourceLoadsToNil() throws {
        try withBundle(licensesJSON: nil) { bundle in
            #expect(LicenseCatalog.load(from: bundle) == nil)
        }
    }

    @Test(
        "a list that will not decode loads to nil rather than trapping",
        arguments: [
            // Truncated: a write that did not finish.
            #"{"app": {"license": "AGPL-3.0-or-later", "text": "GNU AFFERO"#,
            // Whole, valid JSON — just not this shape: `app.text` missing.
            #"{"app": {"license": "AGPL-3.0-or-later"}, "packages": []}"#,
        ]
    )
    func undecodableListLoadsToNil(json: String) throws {
        try withBundle(licensesJSON: json) { bundle in
            #expect(LicenseCatalog.load(from: bundle) == nil)
        }
    }

    /// All the two pages have left to show when the list is gone. It is
    /// derived from ``SourceRepository``, so an `isCurrent` that moved
    /// would leave the fallback with nothing to link to either.
    @Test("the fallback link points at the current repository's licence list")
    func fallbackLinkPointsAtTheRepositoryLicenseList() throws {
        let current = SourceRepository.all.first(where: \.isCurrent)
        let repository = try #require(current)
        let fallback = try #require(LicenseCatalog.fallbackLicenseURL)
        #expect(fallback.absoluteString == repository.url.absoluteString + "/blob/main/swift/TigerDuck/licenses.json")
    }

    /// A bundle laid out flat, the way the app's own is, carrying whatever
    /// `licenses.json` the caller wants — or none at all.
    private func withBundle(licensesJSON: String?, _ body: (Bundle) throws -> Void) throws {
        let directory = URL.temporaryDirectory
            .appending(path: "LicenseCatalogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if let licensesJSON {
            try licensesJSON.write(
                to: directory.appending(path: "licenses.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        try body(#require(Bundle(url: directory)))
    }
}
