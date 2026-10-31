import SwiftUI
import TigerDuckCore

struct MoodleMaterialsView: View {
    let store: MoodleCourseStore
    let policy: VisualStylePolicy

    @Environment(\.openURL) private var openURL
    @Environment(\.openMoodleLink) private var openMoodleLink
    @State private var files = MoodleFileOpener()
    @State private var isLaidOut = false
    @State private var hasScrolledToWeek = false

    var body: some View {
        let currentWeek = currentWeekSectionId
        ScrollViewReader { proxy in
            // Not a List: a long press there lifts the whole row, here a week's card, rather than
            // the file under the finger.
            ScrollView {
                if let materials = store.materials.value {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(materials.sections.enumerated()), id: \.element.id) { index, section in
                            sectionView(section, isFirst: index == 0, isCurrentWeek: section.id == currentWeek)
                                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                                .padding(.vertical, TigerDuckTheme.Spacing.xs)
                        }
                    }
                } else {
                    MoodleFirstLoadView(
                        failure: store.materials.isRefreshing ? nil : store.materials.failure,
                        retry: { await store.refreshMaterials() }
                    )
                }
            }
            // A scrollTo before the scroll view's first layout does nothing, and a summary still
            // loading can change the week: its format decides how the week is found.
            .onGeometryChange(for: Bool.self, of: { $0.size.height > 0 }) { isLaidOut = $0 }
            .onChange(of: isLaidOut && !store.summary.isRefreshing ? currentWeek : nil, initial: true) { _, section in
                guard let section, !hasScrolledToWeek else { return }
                hasScrolledToWeek = true
                proxy.scrollTo(section, anchor: .top)
            }
        }
        .background(Color.backgroundPrimary)
        .refreshable { await store.refreshMaterials() }
        .moodleRefreshFailureNote(store.materials, hasContent: store.materials.value != nil)
        .moodleListChrome(
            title: String(localized: "course_detail_files_label"),
            page: .course(store.courseId),
            willOpenPage: { files.forgetPendingOpen() },
            refresh: { await store.refreshMaterials() }
        )
        .moodleAutoRefresh(every: store.materials.ttl, fetchedAt: { store.materialsFetchedAt }) {
            await store.refreshMaterials()
        }
        .moodleFilePresentation(files)
    }

    /// The course's details come from the summary call, which the course page keeps fresh.
    private var currentWeekSectionId: Int? {
        guard let sections = store.materials.value?.sections else { return nil }
        let course = store.summary.value
        return MoodleCurrentWeek.sectionId(
            in: sections, format: course?.format, startDate: course?.startDate,
            now: AppClock.now(), calendar: TaipeiTime.calendar
        )
    }

    private func sectionView(_ section: MoodleMaterialSection, isFirst: Bool, isCurrentWeek: Bool) -> some View {
        let rows = MoodleMaterialRow.rows(of: section)
        let neighbours = section.materials.flatMap(\.fileRefs)
        return VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            if !section.name.isEmpty {
                Text(section.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isCurrentWeek ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.textSecondary))
                    .lineLimit(2)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.top, isFirst ? 0 : TigerDuckTheme.Spacing.sm)
                    .accessibilityAddTraits(isCurrentWeek ? [.isHeader, .isSelected] : .isHeader)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().padding(.leading, MoodleFileRow.textInset + row.indent)
                    }
                    rowView(row, neighbours: neighbours)
                }
            }
            .presetCard(policy: policy)
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
                openInMoodle: { open(page) }
            )
        case .link(let url):
            MoodleLinkRow(
                title: material.name,
                url: url,
                open: {
                    files.forgetPendingOpen()
                    openMoodleLink(url)
                    store.open(material)
                },
                share: { files.share(link: url) },
                openInMoodle: { open(page) }
            )
        case .folder(let count):
            MoodleFolderRow(name: material.name, fileCount: count)
        }
    }

    private func open(_ page: MoodlePage) {
        files.forgetPendingOpen()
        Task { await openURL(page) }
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
