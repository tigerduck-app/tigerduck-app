import SwiftUI

/// A course's syllabus, pushed from the course detail sheet with the copy the sheet fetched.
struct CourseSyllabusView: View {
    let syllabus: CourseSyllabus
    let policy: VisualStylePolicy
    private let gradingParts: [CourseSyllabusBreakdown.Part]?
    private let teachingParts: [CourseSyllabusBreakdown.Part]?

    @Environment(\.openMoodleLink) private var openMoodleLink

    init(syllabus: CourseSyllabus, policy: VisualStylePolicy) {
        self.syllabus = syllabus
        self.policy = policy
        gradingParts = syllabus.grading.flatMap(CourseSyllabusBreakdown.grading)
        teachingParts = CourseSyllabusBreakdown.teaching(syllabus)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                if let grading = syllabus.grading {
                    card(String(localized: "course_detail_syllabus_grading")) {
                        if let parts = gradingParts {
                            CourseSyllabusBreakdownView(parts: parts)
                        } else {
                            Self.text(grading)
                        }
                    }
                }
                if let outline = syllabus.outline {
                    card(String(localized: "course_detail_syllabus_outline")) { Self.text(outline) }
                }
                if let teaching = teachingParts {
                    card(String(localized: "course_detail_syllabus_method")) {
                        CourseSyllabusBreakdownView(parts: teaching)
                    }
                }
                if !details.isEmpty {
                    detailsCard
                }
                if let website = syllabus.website {
                    websiteRow(website)
                }
            }
            .padding(TigerDuckTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.backgroundPrimary)
        .moodleListChrome(title: String(localized: "course_detail_syllabus"), page: nil, refresh: {})
    }

    private var details: [(heading: String, text: String)] {
        [
            (String(localized: "course_detail_syllabus_content"), syllabus.content),
            (String(localized: "course_detail_syllabus_references"), syllabus.references),
            (String(localized: "course_detail_syllabus_notes"), syllabus.notes),
            (String(localized: "course_detail_syllabus_objectives"), syllabus.objectives),
        ].compactMap { heading, text in text.map { (heading, $0) } }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(details.enumerated()), id: \.offset) { index, detail in
                if index > 0 {
                    Divider()
                }
                DisclosureGroup {
                    Self.text(detail.text)
                        .padding(.top, TigerDuckTheme.Spacing.sm)
                } label: {
                    Text(detail.heading)
                        .font(TigerDuckTheme.Typography.headline)
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(TigerDuckTheme.Spacing.lg)
            }
        }
        .presetCard(policy: policy)
    }

    private func websiteRow(_ url: URL) -> some View {
        Button {
            openMoodleLink(url)
        } label: {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                Image(systemName: "globe")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(String(localized: "course_detail_syllabus_website"))
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(TigerDuckTheme.Spacing.lg)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .presetCard(policy: policy)
        .accessibilityAddTraits(.isLink)
    }

    private func card(_ heading: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            Text(heading)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(TigerDuckTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presetCard(policy: policy)
    }

    private static func text(_ text: String) -> some View {
        Text(text)
            .font(TigerDuckTheme.Typography.body)
            .foregroundStyle(Color.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shares as one stacked bar, then a row per part with its color, label and percentage.
struct CourseSyllabusBreakdownView: View {
    let parts: [CourseSyllabusBreakdown.Part]

    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 12

    private static let gap: CGFloat = 2

    private var palette: [Color] {
        let tint = TigerDuckTheme.Tint.self
        return [tint.blue, tint.orange, tint.green, tint.purple, tint.teal, tint.coral, tint.yellow, tint.cyan]
    }

    /// Each part's color, nil for a part with no share in the bar.
    private var colors: [Color?] {
        var next = 0
        return parts.map { part in
            guard let percent = part.percent, percent > 0 else { return nil }
            defer { next += 1 }
            return palette[next % palette.count]
        }
    }

    private typealias Segment = (part: CourseSyllabusBreakdown.Part, percent: Double, color: Color)

    var body: some View {
        let colors = self.colors
        let segments: [Segment] = zip(parts, colors).compactMap { part, color in
            guard let color, let percent = part.percent else { return nil }
            return (part, percent, color)
        }
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            if !segments.isEmpty {
                bar(segments)
            }
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
                ForEach(Array(zip(parts, colors).enumerated()), id: \.offset) { _, row in
                    self.row(row.0, color: row.1)
                }
            }
        }
    }

    private func bar(_ segments: [Segment]) -> some View {
        let total = segments.reduce(0) { $0 + $1.percent }
        return GeometryReader { proxy in
            let width = max(proxy.size.width - Self.gap * CGFloat(segments.count - 1), 0)
            HStack(spacing: Self.gap) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segment.color.frame(width: width * segment.percent / total)
                }
            }
        }
        .frame(height: barHeight)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.map { "\($0.part.label) \(Self.percentText($0.percent))" }.formatted())
    }

    private func row(_ part: CourseSyllabusBreakdown.Part, color: Color?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: "circle.fill")
                .font(TigerDuckTheme.Typography.caption2)
                .foregroundStyle(color ?? .clear)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                Text(part.label)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = part.detail {
                    Text(detail)
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let percent = part.percent {
                Text(Self.percentText(percent))
                    .font(TigerDuckTheme.Typography.body)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func percentText(_ percent: Double) -> String {
        (percent / 100).formatted(.percent)
    }
}
