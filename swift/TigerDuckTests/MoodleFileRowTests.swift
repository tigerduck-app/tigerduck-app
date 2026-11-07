import Foundation
import SwiftUI
import Testing
import TigerDuckCore
@testable import TigerDuck

@MainActor
struct MoodleFileRowTests {
    static let now = TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 9))!
    static let october4 = TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 15))!

    @Test("a file's type is its extension in capitals, with tar's compound endings shortened")
    func typeLabel() {
        let labels: KeyValuePairs<String, String?> = [
            "slides.pdf": "PDF",
            "SLIDES.PDF": "PDF",
            "Week 3 lecture notes.pptx": "PPTX",
            "data.7z": "7Z",
            "lab4.tar": "TAR",
            "lab4.tar.gz": "TGZ",
            "lab4.TAR.GZ": "TGZ",
            "lab4.TGZ": "TGZ",
            "lab4.tar.bz2": "TBZ2",
            "lab4.tbz2": "TBZ2",
            "lab4.tar.xz": "TXZ",
            "lab4.txz": "TXZ",
        ]
        for (name, label) in labels {
            #expect(MoodleFileKind.typeLabel(of: name) == label, "\(name)")
        }
    }

    @Test("a name without an extension of one to five ASCII letters or digits has no type")
    func noTypeLabel() {
        for name in ["Makefile", "file.", "notes.markdown", ".bashrc", "slides.pdf?forcedownload=1", "report.ｐｄｆ", ""] {
            #expect(MoodleFileKind.typeLabel(of: name) == nil, "\(name)")
        }
    }

    @Test("the type follows whichever of the date and size the line has, joined the same way")
    func line() {
        let size = ByteCountFormatter.string(fromByteCount: 646_000, countStyle: .file)
        func line(_ name: String, _ bytes: Int64?, _ modified: Date?) -> String {
            MoodleFileRow.subline(name: name, size: bytes, modified: modified, now: Self.now)
        }
        #expect(line("slides.pdf", 646_000, Self.october4) == "10/04 · \(size) · PDF")
        #expect(line("lab4.tar.gz", 646_000, nil) == "\(size) · TGZ")
        #expect(line("lab4.tar.gz", nil, Self.october4) == "10/04 · TGZ")
        #expect(line("lab4.tar.gz", nil, nil) == "TGZ")
        #expect(line("Makefile", 646_000, Self.october4) == "10/04 · \(size)")
        #expect(line("Makefile", nil, nil) == "")
    }
}

#if os(iOS)
@MainActor
@Suite(.serialized)
struct MoodleFileRowScreenTests {
    private static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
    private static let longName = "期中專題報告_第三組_final_revision_2026_v12_含附錄與原始資料.tar.gz"

    private static let files = [
        file(longName, size: 646_000, modified: MoodleFileRowTests.october4),
        file("Week 3 slides.pdf", size: 2_400_000, modified: MoodleFileRowTests.october4),
        file("Makefile", size: 812, modified: nil),
    ]

    private static func file(_ name: String, size: Int, modified: Date?) -> MoodleFile {
        MoodleFile(
            name: name, size: size, url: "https://moodle-stub.invalid/webservice/pluginfile.php/31/mod_resource/content/1/file",
            mimeType: nil, modified: modified
        )
    }

    private struct Rows: View {
        var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(MoodleFileRowScreenTests.files.enumerated()), id: \.offset) { index, file in
                        if index > 0 { Divider().padding(.leading, MoodleFileRow.textInset) }
                        MoodleFileRow(
                            title: file.name, file: file, state: .notDownloaded, now: MoodleFileRowTests.now,
                            tap: {}, share: {}, openInMoodle: {}
                        )
                    }
                }
                .presetCard(policy: VisualStylePolicy(preset: .default))
                .padding(TigerDuckTheme.Spacing.lg)
            }
            .background(Color.backgroundPrimary)
        }
    }

    @Test("a file row's line ends with the file's type and stays inside the screen", arguments: ArchiveScreensTests.looks)
    func rows(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let window = try ClubScreensTests.show(Rows(), look: look, height: 1100)
            defer { window.isHidden = true }
            try await waitUntil { accessibilityElement(labeled: "Makefile", in: window) != nil }
            window.saveSnapshot(as: "file-rows-\(look.testDescription)-\(Self.language)")

            let size = ByteCountFormatter.string(fromByteCount: 646_000, countStyle: .file)
            #expect(accessibilityElement(labeled: Self.longName, in: window)?.accessibilityValue == "10/04 · \(size) · TGZ")
            #expect(accessibilityElement(labeled: "Week 3 slides.pdf", in: window)?.accessibilityValue?.hasSuffix(" · PDF") == true)
            #expect(accessibilityElement(labeled: "Makefile", in: window)?.accessibilityValue
                == ByteCountFormatter.string(fromByteCount: 812, countStyle: .file))
            for file in Self.files {
                let row = try #require(accessibilityElement(labeled: file.name, in: window), "\(file.name)")
                #expect(row.accessibilityFrame.minX >= 0 && row.accessibilityFrame.maxX <= window.bounds.maxX + 0.5, "\(file.name)")
            }
        }
    }
}
#endif
