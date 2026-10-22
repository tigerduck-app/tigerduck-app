#if os(iOS)
import SwiftUI
import UIKit

///
struct ClassTableExportView: View {
    let viewModel: ClassTableViewModel
    let owner: String?
    /// The page's Differentiate Without Color, handed to the grid directly:
    /// the renderer's environment cannot carry it.
    let differentiateWithoutColor: Bool

    static let width: CGFloat = 390

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.displayLabel(for: viewModel.currentSemester))
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: TigerDuckTheme.Spacing.sm)
                if let owner, !owner.isEmpty {
                    Text(owner)
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
        .background(Color.backgroundPrimary)
    }
}

@MainActor
enum ClassTableExporter {
    /// Draws ``ClassTableExportView`` into a PNG in the temporary directory
    /// and returns its URL, or `nil` when nothing could be drawn or written.
    /// Hand the URL to ``discard(_:)`` once it has been shared.
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
        let owner = viewModel.shownPerson?.nickname ?? appState.authService.storedStudentId
        let content = ClassTableExportView(
            viewModel: viewModel,
            owner: owner,
            differentiateWithoutColor: differentiateWithoutColor
        )
            .environment(appState)
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
        renderer.isOpaque = true
        guard let image = renderer.uiImage else { return nil }

        let name = fileName(
            title: String(localized: "feature_class_table"),
            semesterLabel: viewModel.displayLabel(for: viewModel.currentSemester),
            // A nickname has no length limit, and a file name past 255 bytes cannot be written.
            studentId: owner.map { String($0.prefix(40)) }
        )
        // Drawing needs the main actor; encoding a 3x PNG and writing it does
        // not, and is the slower half.
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let data = image.pngData() else { return nil }
            let fileManager = FileManager.default
            removeLeftovers(fileManager)
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

    nonisolated static func discard(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == exportRoot.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private nonisolated static var exportRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ClassTableExport", isDirectory: true)
    }

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
