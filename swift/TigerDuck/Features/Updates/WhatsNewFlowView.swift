#if os(iOS)
import SwiftUI

struct WhatsNewFlowView: View {
    let presentation: WhatsNewPresentation
    let onFinish: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var isRequesting = false
    @State private var requestTask: Task<Void, Never>?

    private var stepCount: Int {
        presentation.pages.count + (presentation.summary == nil ? 0 : 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            pager
            footer
        }
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
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(0..<stepCount, id: \.self) { step in
                    Group {
                        if abs(step - index) <= 1 {
                            content(at: step)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityHidden(step != index)
                }
            }
            // An RTL HStack lays steps out right to left, but SwiftUI
            // mirrors `offset(x:)` under RTL as well, so the same
            // negative offset brings the next step in either way.
            .offset(x: -CGFloat(index) * proxy.size.width)
        }
        .clipped()
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
                    appState: appState,
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
                        apply(appState)
                        advance()
                    }
                    secondaryButton(decline.resolved(for: presentation.language), action: advance)
                }
            case .permission(_, let confirm, let decline, let request):
                VStack(spacing: TigerDuckTheme.Spacing.sm) {
                    primaryButton(confirm.resolved(for: presentation.language), isBusy: isRequesting) {
                        isRequesting = true
                        requestTask = Task {
                            await request(appState)
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
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
            index = step
        }
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
