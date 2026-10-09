#if os(iOS)
import SwiftUI
import UIKit

/// The class table as it goes into an exported image: whose it is and which
/// term above, then the same grid the page draws.
///
/// The grid is the live `TimetableGridView`, not a copy, so the image keeps
/// whatever the page shows: colours, custom and abbreviated names, the
/// start / period / end column, the room hint when it is switched on.
/// Only the assignment badge stays out; see
/// ``TimetableGridView/showsAssignmentBadges``.
struct ClassTableExportView: View {
    let viewModel: ClassTableViewModel
    let studentId: String?
    /// The page's Differentiate Without Color, handed to the grid directly:
    /// the renderer's environment cannot carry it.
    let differentiateWithoutColor: Bool

    /// A phone's width whatever the device, so an export from an iPad is
    /// still a picture that reads at a glance when it lands on a phone.
    static let width: CGFloat = 390

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.displayLabel(for: viewModel.currentSemester))
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: TigerDuckTheme.Spacing.sm)
                if let studentId, !studentId.isEmpty {
                    Text(studentId)
                        .font(TigerDuckTheme.Typography.body)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            TimetableGridView(
                viewModel: viewModel,
                showsAssignmentBadges: false,
                differentiateWithoutColor: differentiateWithoutColor
            )
        }
        .padding(.vertical, TigerDuckTheme.Spacing.lg)
        .frame(width: Self.width)
        // Opaque: the cells are translucent course colours, and over a
        // transparent PNG they would take on whatever the viewer puts behind.
        .background(Color.backgroundPrimary)
    }
}

@MainActor
enum ClassTableExporter {
    /// Draws ``ClassTableExportView`` into a PNG in the temporary directory
    /// and returns its URL, or `nil` when nothing could be drawn or written.
    /// Hand the URL to ``discard(_:)`` once it has been shared.
    ///
    /// `ImageRenderer` starts from an empty environment rather than the one
    /// the page sits in, so everything the grid reads from it is handed over
    /// explicitly.
    static func render(
        viewModel: ClassTableViewModel,
        appState: AppState,
        dynamicTypeSize: DynamicTypeSize,
        layoutDirection: LayoutDirection,
        legibilityWeight: LegibilityWeight?,
        differentiateWithoutColor: Bool
    ) async -> URL? {
        let studentId = appState.authService.storedStudentId
        let content = ClassTableExportView(
            viewModel: viewModel,
            studentId: studentId,
            differentiateWithoutColor: differentiateWithoutColor
        )
            .environment(appState)
            // The app pins dark (`TigerDuckApp`), and the page's colours are
            // written for it.
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            // A right-to-left language mirrors the page's grid; the empty
            // environment would draw it left-to-right.
            .environment(\.layoutDirection, layoutDirection)
            // Bold Text. Differentiate Without Color cannot be set here, so
            // it rides on the view instead.
            .environment(\.legibilityWeight, legibilityWeight)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        // The background is opaque, so an alpha channel only costs encode
        // time and bytes.
        renderer.isOpaque = true
        guard let image = renderer.uiImage else { return nil }

        let name = fileName(
            title: String(localized: "feature_class_table"),
            semesterLabel: viewModel.displayLabel(for: viewModel.currentSemester),
            studentId: studentId
        )
        // Drawing needs the main actor; encoding a 3x PNG and writing it does
        // not, and is the slower half.
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let data = image.pngData() else { return nil }
            let fileManager = FileManager.default
            removeLeftovers(fileManager)
            // A directory of its own per export, so the file inside keeps the
            // readable name and two exports never touch each other's file —
            // Home's class table and the Class Table tab each have the menu.
            let directory = exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let url = directory.appendingPathComponent(name)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                try? fileManager.removeItem(at: directory)
                return nil
            }
        }.value
    }

    /// Deletes an export once its share sheet has closed: it carries a
    /// student id, and nothing points at it any more. Only ever a directory
    /// ``render`` made.
    nonisolated static func discard(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == exportRoot.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private nonisolated static var exportRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ClassTableExport", isDirectory: true)
    }

    /// Exports ``discard(_:)`` never reached — the app ended while a share
    /// sheet was up. Ten minutes is far longer than any export takes to
    /// reach its share sheet, and only one share sheet can be up at a time.
    private nonisolated static func removeLeftovers(_ fileManager: FileManager) {
        let cutoff = Date().addingTimeInterval(-10 * 60)
        let entries = (try? fileManager.contentsOfDirectory(
            at: exportRoot,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? fileManager.removeItem(at: entry) }
        }
    }

    /// "Class_table_114-2_B11315000.png": the name the file keeps wherever it
    /// is saved or sent, so it says what it is and whose. Underscores, never
    /// spaces, between the parts and inside them, so the name survives a URL
    /// or a command line without quoting or %20. The student id is left out,
    /// not left as a trailing underscore, when there is none.
    nonisolated static func fileName(title: String, semesterLabel: String, studentId: String?) -> String {
        let parts = [title, semesterLabel, studentId ?? ""]
            .map {
                $0.components(separatedBy: unsafeFileNameCharacters).joined()
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: "_")
            }
            .filter { !$0.isEmpty }
        return parts.joined(separator: "_") + ".png"
    }

    /// Path separators, the characters Files and FAT-formatted drives
    /// refuse, and control characters.
    private nonisolated static let unsafeFileNameCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
        .union(.controlCharacters)
}
#endif
