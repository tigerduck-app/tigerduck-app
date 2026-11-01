#if os(iOS)
import SwiftUI

struct WhatsNewFlowView: View {
    let presentation: WhatsNewPresentation
    let onFinish: () -> Void

    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var isRequesting = false
    @State private var requestTask: Task<Void, Never>?
    @State private var position = WhatsNewPagerPosition()

    private var pageTurn: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.4)
    }

    private var stepCount: Int {
        presentation.pages.count + (presentation.summary == nil ? 0 : 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            pager
            footer
        }
        .animation(pageTurn, value: index)
        .environment(\.whatsNewLanguage, presentation.language)
        .onDisappear { requestTask?.cancel() }
    }

    private var header: some View {
        HStack {
            if index > 0 {
                Button {
                    go(to: index - 1)
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "action_back"))
                .disabled(isRequesting)
                .transition(.opacity)
            }
            Spacer()
        }
        .frame(height: 44)
        .padding(.horizontal, TigerDuckTheme.Spacing.sm)
        .padding(.top, TigerDuckTheme.Spacing.sm)
    }

    private var pager: some View {
        WhatsNewPager(count: stepCount, index: $index, position: $position, lockedPages: lockedPages) { step in
            content(at: step)
        }
        .scrollDisabled(isRequesting)
    }

    private var lockedPages: Set<Int> {
        Set(presentation.pages.indices.filter { presentation.pages[$0].locksForwardSwipe })
    }

    private var footer: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            if stepCount > 1 {
                WhatsNewPageDots(count: stepCount, current: index)
            }
            ZStack {
                controls(at: index)
                    .id(index)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.xl)
        .padding(.top, TigerDuckTheme.Spacing.md)
        .padding(.bottom, TigerDuckTheme.Spacing.xl)
    }

    private func content(at step: Int) -> some View {
        stepContent(at: step)
            .environment(\.whatsNewPageIsCurrent, step == index)
    }

    @ViewBuilder
    private func stepContent(at step: Int) -> some View {
        if step < presentation.pages.count {
            WhatsNewPageContentView(
                page: presentation.pages[step],
                context: WhatsNewPageContext(
                    app: app,
                    language: presentation.language,
                    advance: advance
                )
            )
        } else if let summary = presentation.summary {
            WhatsNewSummaryContent(entry: summary, isActive: step == index)
        }
    }

    @ViewBuilder
    private func controls(at step: Int) -> some View {
        if step < presentation.pages.count {
            switch presentation.pages[step].kind {
            case .feature, .choice, .toggle:
                primaryButton(nextTitle(at: step), action: advance)
            case .custom(let showsNextButton, _):
                if showsNextButton {
                    primaryButton(nextTitle(at: step), action: advance)
                }
            case .optIn(_, let confirm, let decline, let apply):
                VStack(spacing: TigerDuckTheme.Spacing.sm) {
                    primaryButton(confirm.resolved(for: presentation.language)) {
                        apply(app)
                        advance()
                    }
                    secondaryButton(decline.resolved(for: presentation.language), action: advance)
                }
            case .permission(_, let confirm, let decline, let request):
                VStack(spacing: TigerDuckTheme.Spacing.sm) {
                    primaryButton(confirm.resolved(for: presentation.language), isBusy: isRequesting) {
                        isRequesting = true
                        requestTask = Task {
                            await request(app)
                            isRequesting = false
                            requestTask = nil
                            guard !Task.isCancelled else { return }
                            advance()
                        }
                    }
                    secondaryButton(decline.resolved(for: presentation.language), action: advance)
                        .disabled(isRequesting)
                }
            }
        } else {
            primaryButton(String(localized: "whats_new_continue"), action: onFinish)
        }
    }

    private func nextTitle(at step: Int) -> String {
        step == stepCount - 1
            ? String(localized: "whats_new_continue")
            : String(localized: "action_next")
    }

    private func primaryButton(_ title: String, isBusy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isBusy ? 0 : 1)
                if isBusy { ProgressView() }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, TigerDuckTheme.Spacing.md)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isBusy)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, TigerDuckTheme.Spacing.md)
        }
        .buttonStyle(.borderless)
    }

    private func advance() {
        if index + 1 < stepCount {
            go(to: index + 1)
        } else {
            onFinish()
        }
    }

    private func go(to step: Int) {
        guard (0..<stepCount).contains(step) else { return }
        withAnimation(pageTurn) {
            position.go(to: step)
        }
    }
}

/// `settledPage` is the page the pager rests on, or the one `go(to:)` sends it to.
struct WhatsNewPagerPosition {
    var scroll = ScrollPosition(idType: Int.self)
    var settledPage = 0

    mutating func go(to step: Int) {
        settledPage = step
        scroll.scrollTo(id: step)
    }
}

struct WhatsNewPager<Page: View>: View {
    let count: Int
    @Binding var index: Int
    @Binding var position: WhatsNewPagerPosition
    let lockedPages: Set<Int>
    @ViewBuilder let page: (Int) -> Page

    private struct Spot: Equatable {
        let step: Int
        let restingPage: Int?
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { step in
                        Group {
                            if abs(step - index) <= 1 {
                                page(step)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .accessibilityHidden(step != index)
                    }
                }
                .scrollTargetLayout()
                .background(ForwardPagingLock(isLocked: lockedPages.contains(position.settledPage)))
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition($position.scroll)
            // The scroll position's view identity follows only a drag, not VoiceOver's
            // three-finger swipe; the visible rect follows every scroll.
            .onScrollGeometryChange(for: Spot.self, of: Self.spot(in:)) { _, spot in
                follow(spot)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// VoiceOver's three-finger swipe moves the pager without the pan gesture that
    /// `ForwardPagingLock` watches, so a scroll past a locked page is sent back to it.
    private func follow(_ spot: Spot) {
        let settled = position.settledPage
        let step = min(max(spot.step, 0), count - 1)
        if lockedPages.contains(settled), step > settled {
            index = settled
            position.scroll.scrollTo(id: settled)
            return
        }
        index = step
        if let page = spot.restingPage, page != settled {
            position.settledPage = page
        }
    }

    private static func spot(in geometry: ScrollGeometry) -> Spot {
        let width = geometry.containerSize.width
        guard width > 0 else { return Spot(step: 0, restingPage: nil) }
        let offset = geometry.visibleRect.minX
        let nearest = (offset / width).rounded()
        return Spot(
            step: Int((geometry.visibleRect.midX / width).rounded(.down)),
            restingPage: abs(offset - nearest * width) < 0.5 ? Int(nearest) : nil
        )
    }
}

extension WhatsNewPage {
    var locksForwardSwipe: Bool {
        if case .custom(false, _) = kind { return true }
        return false
    }
}

extension View {
    func whatsNewSheetPresentation() -> some View {
        presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .keptOverReminders()
    }
}
#endif
