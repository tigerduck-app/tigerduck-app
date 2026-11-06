#if os(iOS)
import SwiftUI

struct ArchiveBrowser: View {
    @State private var model: ArchiveBrowserModel
    @State private var path: [ArchiveFolder]
    @Environment(\.dismiss) private var dismiss

    init(archive: URL, session: URL, path: [ArchiveFolder] = [], limits: ArchiveLimits = ArchiveLimits()) {
        _model = State(initialValue: ArchiveBrowserModel(archive: archive, session: session, limits: limits))
        _path = State(initialValue: path)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ArchiveFolderView(model: model, folder: ArchiveFolder(path: "", name: model.archive.lastPathComponent))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "action_close")) { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: model.shareArchive) {
                            Label(String(localized: "school_mail_attachment_share"), systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .navigationDestination(for: ArchiveFolder.self) { ArchiveFolderView(model: model, folder: $0) }
        }
        .filePreview($model.preview)
        .sheet(item: $model.shared) { ShareSheet(url: $0.url).presentationDetents([.medium, .large]) }
        .alert(String(localized: "file_viewer_cannot_show"), isPresented: showsProblem, presenting: model.problem) { _ in
            Button(String(localized: "file_viewer_open_elsewhere"), action: model.shareArchive)
            Button(String(localized: "action_close"), role: .cancel) {}
        } message: { problem in
            if let reason = problem.reason { Text(reason) }
        }
        .task { await model.load() }
        .task(id: model.opening?.index) { await model.extractOpening() }
    }

    private var showsProblem: Binding<Bool> {
        Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
    }
}

struct ArchiveFolderView: View {
    let model: ArchiveBrowserModel
    let folder: ArchiveFolder

    @Environment(AppEnvironment.self) private var app: AppEnvironment?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.backgroundPrimary)
            .navigationTitle(folder.name)
            .inlineNavigationTitle()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .failed(let problem):
            ContentUnavailableView {
                Label(String(localized: "file_viewer_cannot_show"), systemImage: "doc.zipper")
            } description: {
                if let reason = problem?.reason { Text(reason) }
            } actions: {
                Button(String(localized: "file_viewer_open_elsewhere"), action: model.shareArchive)
            }
        case .listed(let tree, let truncatedAt):
            let nodes = tree.children(of: folder.path)
            if nodes.isEmpty, folder.path.isEmpty {
                ContentUnavailableView(String(localized: "file_viewer_archive_empty"), systemImage: "doc.zipper")
            } else {
                list(nodes, tree: tree, truncatedAt: folder.path.isEmpty ? truncatedAt : nil)
            }
        }
    }

    private func list(_ nodes: [ArchiveNode], tree: ArchiveTree, truncatedAt: Int?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        if index > 0 { Divider().padding(.leading, MoodleFileRow.textInset) }
                        ArchiveNodeRow(node: node, tree: tree, model: model)
                    }
                }
                .presetCard(policy: app?.preferences.visualStylePolicy ?? VisualStylePolicy(preset: .default))
                if let truncatedAt {
                    Text(String(format: String(localized: "file_viewer_archive_truncated"), truncatedAt.formatted()))
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.vertical, TigerDuckTheme.Spacing.md)
        }
    }
}
#endif
