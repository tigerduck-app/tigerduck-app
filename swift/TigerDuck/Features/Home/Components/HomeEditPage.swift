import SwiftUI

private let sectionDragContainerID = "home-sections"

/// Home while it is being arranged. A section with live content shows only its outline, so the
/// order reads at a glance and nothing loads or updates; the edit controls are all that respond.
/// It is a stack, not a List: in a List row SwiftUI hands every `.draggable` to the List, which
/// then drags the row's first widget wherever the press lands.
struct HomeEditPage<Header: View>: View {
    let viewModel: HomeViewModel
    let sections: [HomeSection]
    let scrollAnchor: HomeScrollAnchor
    @ViewBuilder let header: () -> Header

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeSectionDrag: ReorderDragPayload?
    @State private var didReorderSection = false

    var body: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                header()

                ForEach(sections) { section in
                    sectionCell(section)
                        .homeScrollAnchor(section.id, in: scrollAnchor)
                }
            }
            .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            .onDrop(
                of: [.tigerDuckReorderPayload],
                delegate: ReorderContainerDropDelegate(
                    expectedKind: .homeSection,
                    containerID: sectionDragContainerID,
                    activePayload: $activeSectionDrag,
                    didReorder: $didReorderSection,
                    onPersist: viewModel.saveSectionLayout
                )
            )
            .contentShape(Rectangle())
        }
        .homeScrollTop(in: scrollAnchor)
        .onDisappear {
            ReorderDropSupport.finalizeDrop(
                activePayload: $activeSectionDrag,
                didReorder: $didReorderSection,
                onPersist: viewModel.saveSectionLayout
            )
        }
    }

    private func sectionCell(_ section: HomeSection) -> some View {
        let payload = ReorderDragPayload(id: section.id, kind: .homeSection, containerID: sectionDragContainerID)
        // The handle sits above the outline, which is mostly its header, instead of covering it.
        return VStack(spacing: 0) {
            SectionDragHandle()
            sectionOutline(section)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(reduceMotion ? nil : .smoothSpring) {
                    viewModel.removeSection(section)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .red)
                    .font(.title3)
            }
            .accessibilityLabel(String(localized: "action_remove"))
            .accessibilityValue(section.displayTitle)
            .padding(.trailing, TigerDuckTheme.Spacing.lg)
        }
        .opacity(activeSectionDrag?.id == section.id ? 0.35 : 1)
        .draggable(payload) {
            SectionDragPreview(section: section)
                .onAppear { activeSectionDrag = payload }
        }
        .onDrop(
            of: [.tigerDuckReorderPayload],
            delegate: ReorderDropDelegate(
                targetID: section.id,
                expectedKind: .homeSection,
                containerID: sectionDragContainerID,
                activePayload: $activeSectionDrag,
                didReorder: $didReorderSection,
                currentIDs: { viewModel.sections.map(\.id) },
                moveAction: { fromOffsets, destination in
                    viewModel.sections.move(fromOffsets: fromOffsets, toOffset: destination)
                },
                onPersist: viewModel.saveSectionLayout
            )
        )
    }

    @ViewBuilder
    private func sectionOutline(_ section: HomeSection) -> some View {
        switch section.type {
        case .todayCourses, .upcomingAssignments:
            SectionPlaceholder(section: section)
        case .quickWidgets, .custom:
            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                SectionHeader(title: section.title)
                WidgetGridView(
                    widgets: Binding(
                        get: { viewModel.sections.first { $0.id == section.id }?.widgets ?? [] },
                        set: { newWidgets in
                            if let index = viewModel.sections.firstIndex(where: { $0.id == section.id }) {
                                viewModel.sections[index].widgets = newWidgets
                            }
                        }
                    ),
                    isEditing: true,
                    dragContainerID: section.id,
                    onRemove: { widget in
                        withAnimation(reduceMotion ? nil : .smoothSpring) {
                            viewModel.removeWidget(from: section.id, widget: widget)
                        }
                    },
                    onReorder: viewModel.saveSectionLayout
                )
            }
        }
    }
}

private extension HomeSection {
    /// The time machine's live header always reads the current language's title.
    var displayTitle: String { type == .todayCourses ? type.defaultTitle : title }
}

/// The header of a section with live content and the shape of its rows.
private struct SectionPlaceholder: View {
    let section: HomeSection

    @ScaledMetric private var lineHeight: CGFloat = 10
    @ScaledMetric private var pickerHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            SectionHeader(title: section.displayTitle)

            Group {
                if section.type == .todayCourses {
                    card
                    Capsule()
                        .fill(Color.emptyCellFill)
                        .frame(height: TimeSliderMetrics.fluidTrackHeight)
                } else {
                    Capsule()
                        .fill(Color.emptyCellFill)
                        .frame(height: pickerHeight)
                    ForEach(0..<3, id: \.self) { _ in card }
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .accessibilityHidden(true)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            line.padding(.trailing, TigerDuckTheme.Spacing.xxl * 3)
            line
        }
        .cardPadding()
        .glassCard()
    }

    private var line: some View {
        Capsule()
            .fill(Color.emptyCellFill)
            .frame(maxWidth: .infinity)
            .frame(height: lineHeight)
    }
}

private struct SectionDragHandle: View {
    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.xs) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.bold))
            Text(String(localized: "home_section_drag_hint"))
                .font(TigerDuckTheme.Typography.caption2)
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, TigerDuckTheme.Spacing.md)
        .padding(.vertical, TigerDuckTheme.Spacing.xs)
        .background(
            Capsule().fill(Color(.systemGray5))
        )
        .padding(.top, TigerDuckTheme.Spacing.xs)
    }
}

private struct SectionDragPreview: View {
    let section: HomeSection

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: section.type.iconName)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(section.displayTitle)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(TigerDuckTheme.Spacing.lg)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        )
    }
}
