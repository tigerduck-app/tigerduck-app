#if os(iOS)
import SwiftUI
import UIKit

/// The class table as it goes into an exported image: whose it is and which
/// term above, then the same grid the page draws.
///
/// The grid is the live `TimetableGridView`, not a copy, so the image keeps
/// whatever the page shows — colours, custom and abbreviated names, the
/// start / 節 / end period column, the room hint when it is switched on.
/// Only the assignment badge stays out; see
/// ``TimetableGridView/showsAssignmentBadges``.
struct ClassTableExportView: View {
    let viewModel: ClassTableViewModel
    let studentId: String?

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

            TimetableGridView(viewModel: viewModel, showsAssignmentBadges: false)
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
    ///
    /// `ImageRenderer` starts from an empty environment rather than the one
    /// the page sits in, so everything the grid reads from it is handed over
    /// explicitly.
    static func render(
        viewModel: ClassTableViewModel,
        appState: AppState,
        dynamicTypeSize: DynamicTypeSize,
        layoutDirection: LayoutDirection,
        legibilityWeight: LegibilityWeight?
    ) async -> URL? {
        let studentId = appState.authService.storedStudentId
        let content = ClassTableExportView(viewModel: viewModel, studentId: studentId)
            .environment(appState)
            // The app pins dark (`TigerDuckApp`), and the page's colours are
            // written for it.
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            // A right-to-left language mirrors the page's grid; the empty
            // environment would draw it left-to-right.
            .environment(\.layoutDirection, layoutDirection)
            // Bold Text. Differentiate Without Color cannot follow: SwiftUI
            // does not let it be set, so a 衝堂 cluster's warning triangle
            // stays off the image.
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
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("ClassTableExport", isDirectory: true)
            let url = directory.appendingPathComponent(name)
            do {
                // Only the newest export is kept: an older one carries a
                // student id and nothing points at it any more.
                try? fileManager.removeItem(at: directory)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }.value
    }

    /// "課表_114-2_B11315000.png": the name the file keeps wherever it is
    /// saved or sent, so it says what it is and whose. Underscores, never
    /// spaces — between the parts and inside them ("Class_table") — so the
    /// name survives a URL or a command line without quoting or %20. The
    /// student id is left out, not left as a trailing underscore, when
    /// there is none.
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
