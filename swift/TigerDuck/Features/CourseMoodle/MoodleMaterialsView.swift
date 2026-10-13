import SwiftUI

/// A course's materials in the order of its Moodle page, which teachers arrange by week or topic,
/// so the screen keeps Moodle's sections rather than sorting by date or name.
struct MoodleMaterialsView: View {
    let store: MoodleCourseStore

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.openMoodleLink) private var openMoodleLink
    @State private var files = MoodleFileOpener()

    var body: some View {
        List {
            if let materials = store.materials.value {
                ForEach(Array(materials.sections.enumerated()), id: \.element.id) { index, section in
                    sectionView(section, isFirst: index == 0)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(
                            top: TigerDuckTheme.Spacing.xs,
                            leading: TigerDuckTheme.Spacing.lg,
                            bottom: TigerDuckTheme.Spacing.xs,
                            trailing: TigerDuckTheme.Spacing.lg
                        ))
                }
            } else {
                MoodleFirstLoadView(
                    failure: store.materials.isRefreshing ? nil : store.materials.failure,
                    retry: { await store.refreshMaterials() }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .refreshable { await store.refreshMaterials() }
        .moodleListChrome(
            title: String(localized: "course_detail_files_label"),
            status: store.materials.status,
            isLoading: store.materials.isRefreshing,
            page: .course(store.courseId),
            refresh: { await store.refreshMaterials() }
        )
        .moodleAutoRefresh(every: store.materials.ttl, fetchedAt: { store.materialsFetchedAt }) {
            await store.refreshMaterials()
        }
        .moodleFilePresentation(files)
    }

    private func sectionView(_ section: MoodleMaterialSection, isFirst: Bool) -> some View {
        let rows = MoodleMaterialRow.rows(of: section)
        let neighbours = section.materials.flatMap(\.fileRefs)
        return VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            if !section.name.isEmpty {
                Text(section.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.top, isFirst ? 0 : TigerDuckTheme.Spacing.sm)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().padding(.leading, MoodleFileRow.textInset + row.indent)
                    }
                    rowView(row, neighbours: neighbours)
                }
            }
            .presetCard(policy: appState.visualStylePolicy)
        }
    }

    @ViewBuilder
    private func rowView(_ row: MoodleMaterialRow, neighbours: [MoodleFileRef]) -> some View {
        let material = row.material
        let page = MoodlePage.module(material.module, cmid: material.id)
        switch row.kind {
        case .file(let file):
            let ref = MoodleFileRef(file: file, owner: .module(material.id))
            MoodleFileRow(
                title: row.indent > 0 ? file.name : material.name,
                file: file,
                state: store.downloadState(of: file, in: ref.owner),
                indent: row.indent,
                tap: { files.tap(ref, among: neighbours, store: store) { store.open(material) } },
                share: { files.share(ref, store: store) },
                openInMoodle: { Task { await openURL(page) } }
            )
        case .link(let url):
            MoodleLinkRow(
                title: material.name,
                url: url,
                open: {
                    files.open(link: url) { openMoodleLink($0) }
                    store.open(material)
                },
                share: { files.share(link: url) },
                openInMoodle: { Task { await openURL(page) } }
            )
        case .folder(let count):
            MoodleFolderRow(name: material.name, fileCount: count)
        }
    }
}

struct MoodleMaterialRow: Identifiable {
    enum Kind {
        case file(MoodleFile)
        case link(URL)
        case folder(fileCount: Int)
    }

    let material: MoodleMaterial
    let kind: Kind
    let indent: CGFloat

    var id: String {
        switch kind {
        case .file(let file): "f\(material.id)\(file.path ?? "/")\(file.name)"
        case .link: "l\(material.id)"
        case .folder: "d\(material.id)"
        }
    }

    static func rows(of section: MoodleMaterialSection) -> [MoodleMaterialRow] {
        section.materials.flatMap { material -> [MoodleMaterialRow] in
            switch material.content {
            case .file(let file):
                [MoodleMaterialRow(material: material, kind: .file(file), indent: 0)]
            case .link(let url):
                [MoodleMaterialRow(material: material, kind: .link(url), indent: 0)]
            case .folder(let files):
                [MoodleMaterialRow(material: material, kind: .folder(fileCount: files.count), indent: 0)]
                    + files.map { MoodleMaterialRow(material: material, kind: .file($0), indent: MoodleFileRow.folderIndent) }
            }
        }
    }
}
