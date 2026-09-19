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
}
