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
    @State private var position = PagerPosition()

    private var pageTurn: Animation? {
        reduceMotion ? nil : .pageTurn
    }

    private var stepCount: Int {
        presentation.steps.count
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
        Pager(count: stepCount, index: $index, position: $position, lockedPages: lockedPages) { step in
            content(at: step)
        }
        .scrollDisabled(isRequesting)
    }

    private var lockedPages: Set<Int> {
        Set(presentation.steps.indices.filter {
            if case .page(let page) = presentation.steps[$0] { page.locksForwardSwipe } else { false }
        })
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
        switch presentation.steps[step] {
        case .page(let page):
            WhatsNewPageContentView(
                page: page,
                context: WhatsNewPageContext(
                    app: app,
                    language: presentation.language,
                    advance: advance
                )
            )
        case .summary(let summary):
            WhatsNewSummaryContent(entry: summary, isActive: step == index)
        }
    }

    @ViewBuilder
    private func controls(at step: Int) -> some View {
        switch presentation.steps[step] {
        case .page(let page):
            switch page.kind {
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
        case .summary:
            primaryButton(nextTitle(at: step), action: advance)
        }
    }

    private func nextTitle(at step: Int) -> String {
        String(localized: presentation.advanceTitleKey(at: step))
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
