#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct ArchiveScreensTests {
    private static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
    private static let longName = "\u{671F}\u{4E2D}\u{5C08}\u{984C}\u{5831}\u{544A}_\u{7B2C}\u{4E09}\u{7D44}_final_revision_2026_v12.pdf"

    private static func browser(_ name: String, path: [ArchiveFolder] = []) throws -> (ArchiveBrowser, URL) {
        let session = try ArchiveReaderTests.folder()
        return (ArchiveBrowser(archive: try ArchiveReaderTests.fixture(name), session: session, path: path), session)
    }

    private static func save(_ window: UIWindow, _ state: String, _ look: ClubScreensTests.Look) async throws {
        try await Task.sleep(for: .milliseconds(500))
        window.saveSnapshot(as: "archive-\(state)-\(look.testDescription)-\(language)")
    }

    private static func staysInWindow(_ labels: [String], in window: UIWindow) throws {
        for label in labels {
            let row = try #require(accessibilityElement(labeled: label, in: window), "\(label)")
            #expect(row.accessibilityFrame.minX >= 0 && row.accessibilityFrame.maxX <= window.bounds.maxX + 0.5, "\(label)")
        }
    }

    @Test("the top of an archive lists its folders with their counts, then its files", arguments: ClubScreensTests.looks)
    func root(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let (browser, session) = try Self.browser("lab4_starter.zip")
            defer { try? FileManager.default.removeItem(at: session) }
            let window = try ClubScreensTests.show(browser, look: look)
            defer { window.isHidden = true }
            try await waitUntil { accessibilityElement(labeled: "docs", in: window) != nil }
            try await Self.save(window, "root", look)

            let folder = String(localized: "file_viewer_archive_folder")
            #expect(accessibilityElement(labeled: "docs", in: window)?.accessibilityValue == "\(folder), 4")
            #expect(accessibilityElement(labeled: "samples", in: window)?.accessibilityValue == "\(folder), 128")
            let names = exposedAccessibilityLabels(in: window)
            let order = ["docs", "samples", "src", "tests", "Makefile", "README.md"].compactMap { names.firstIndex(of: $0) }
            #expect(order == order.sorted() && order.count == 6)
            try Self.staysInWindow(["docs", "samples", "README.md"], in: window)
        }
    }

    @Test("a folder of an archive lists its files with their dates and sizes", arguments: ClubScreensTests.looks)
    func folder(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let (browser, session) = try Self.browser("lab4_starter.zip", path: [ArchiveFolder(path: "docs", name: "docs")])
            defer { try? FileManager.default.removeItem(at: session) }
            let window = try ClubScreensTests.show(browser, look: look)
            defer { window.isHidden = true }
            try await waitUntil { accessibilityElement(labeled: "protocol.pdf", in: window) != nil }
            try await Self.save(window, "folder", look)

            let pdf = try #require(accessibilityElement(labeled: "protocol.pdf", in: window))
            #expect(pdf.accessibilityValue?.contains("11/03") == true || pdf.accessibilityValue?.contains("2026") == true)
            try Self.staysInWindow(["diagram.png", "protocol.pdf", "report_template.docx", "rubric.pdf"], in: window)
        }
    }

    @Test("a file in an archive opens in Quick Look", arguments: ClubScreensTests.looks)
    func file(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let (browser, session) = try Self.browser("lab4_starter.zip")
            defer { try? FileManager.default.removeItem(at: session) }
            let window = try ClubScreensTests.show(browser, look: look)
            defer { window.isHidden = true }
            try await waitUntil { accessibilityElement(labeled: Self.longName, in: window) != nil }
            try Self.staysInWindow([Self.longName], in: window)
            _ = accessibilityElement(labeled: Self.longName, in: window)?.accessibilityActivate()
            try await waitUntil { window.rootViewController?.presentedViewController != nil }
            try await Task.sleep(for: .seconds(1))
            try await Self.save(window, "file", look)
            window.rootViewController?.dismiss(animated: false)
        }
    }

    @Test("an archive that can't be read says why and offers another app", arguments: ClubScreensTests.looks)
    func failed(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let (browser, session) = try Self.browser("archive-locked-names.7z")
            defer { try? FileManager.default.removeItem(at: session) }
            let window = try ClubScreensTests.show(browser, look: look)
            defer { window.isHidden = true }
            let reason = String(localized: "file_viewer_archive_password")
            try await waitUntil { ClubScreensTests.shows(reason, in: window) }
            try await Self.save(window, "failed", look)
            #expect(ClubScreensTests.shows(String(localized: "file_viewer_cannot_show"), in: window))
            #expect(ClubScreensTests.shows(String(localized: "file_viewer_open_elsewhere"), in: window))
        }
    }
}
#endif
