import Defaults
import SwiftUI

/// The More sheet: the page's zoom, appearance and desktop site, then find in page and print.
/// In the bottom layout it opens with back, forward and share, which have no button there.
struct BrowserMenu: View {
    let page: BrowserPage
    let showsNavigation: Bool
    /// Runs its work once the sheet has closed, as print presents a sheet of its own.
    let afterClosing: (@escaping () -> Void) -> Void

    @Default(.browserAppearance) private var appearance

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            if showsNavigation { BrowserMoreRow(page: page) }
            card {
                zoomRow
                Divider().padding(.leading, TigerDuckTheme.Spacing.lg)
                appearanceRow
                Divider().padding(.leading, TigerDuckTheme.Spacing.lg)
                Toggle(String(localized: "browser_desktop_site"), isOn: Binding(
                    get: { page.isDesktopSite },
                    set: { page.setDesktopSite($0) }
                ))
                .row()
            }
            card {
                action("magnifyingglass", String(localized: "browser_find")) { page.find.start() }
                Divider().padding(.leading, 52)
                action("printer", String(localized: "browser_print")) { page.print() }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.xl)
        .padding(.bottom, TigerDuckTheme.Spacing.lg)
        .background(BrowserPresentationFade(hidden: page.zoomPeek.isPeeking, shown: page.zoomPeek.sheetShown))
        .onDisappear { page.zoomPeek.stop() }
    }

    private var appearanceRow: some View {
        HStack {
            Text(String(localized: "browser_appearance"))
            Spacer(minLength: TigerDuckTheme.Spacing.md)
            Picker(String(localized: "browser_appearance"), selection: $appearance) {
                Text(String(localized: "common_automatic")).tag(BrowserAppearance.automatic)
                Text(String(localized: "browser_appearance_light")).tag(BrowserAppearance.light)
                Text(String(localized: "browser_appearance_dark")).tag(BrowserAppearance.dark)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .row()
    }

    private var zoomRow: some View {
        HStack {
            Text(String(localized: "browser_zoom"))
            Spacer(minLength: TigerDuckTheme.Spacing.md)
            BrowserZoomButtons(page: page)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { page.zoomPeek.frame = $0 }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { page.zoomPeek.size = $0 }
        }
        .row()
    }

    private func action(_ symbol: String, _ title: String, _ work: @escaping () -> Void) -> some View {
        Button { afterClosing(work) } label: {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24)
                Text(title)
                Spacer(minLength: 0)
            }
            .row()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!page.canUsePage)
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
    }
}

private extension View {
    func row() -> some View {
        padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .frame(minHeight: 52)
    }
}

/// A zoom change fades the More sheet out for a moment, so the page behind shows its new size,
/// and the browser shows a copy of the zoom buttons where the sheet has them.
@Observable
final class BrowserZoomPeek {
    static let duration: Duration = .seconds(1.5)

    /// The sheet's zoom buttons in the window, and their own size, larger while a centered sheet
    /// shows its content scaled down.
    var frame: CGRect?
    var size = CGSize.zero
    private(set) var isPeeking = false
    /// The copy stays until the sheet is back over it.
    private(set) var showsCopy = false
    @ObservationIgnored private var end: Task<Void, Never>?

    func zoom(_ change: () -> Void) {
        change()
        // A faded sheet would leave VoiceOver without the element it was on.
        guard !UIAccessibility.isVoiceOverRunning else { return }
        isPeeking = true
        showsCopy = true
        end?.cancel()
        end = Task {
            try? await Task.sleep(for: Self.duration)
            if !Task.isCancelled { isPeeking = false }
        }
    }

    func sheetShown() {
        if !isPeeking { showsCopy = false }
    }

    func stop() {
        end?.cancel()
        isPeeking = false
        showsCopy = false
    }
}

/// The zoom buttons, in the More sheet and in the copy the browser shows while the sheet is faded.
struct BrowserZoomButtons: View {
    let page: BrowserPage

    var body: some View {
        HStack(spacing: 4) {
            button("textformat.size.smaller", String(localized: "browser_zoom_out"),
                   enabled: BrowserZoom.smaller(than: page.zoom) != nil, page.zoomOut)
            Button { page.zoomPeek.zoom(page.resetZoom) } label: {
                Text((Double(page.zoom) / 100).formatted(.percent))
                    .monospacedDigit()
                    .frame(minWidth: 52)
            }
            .buttonStyle(.plain)
            button("textformat.size.larger", String(localized: "browser_zoom_in"),
                   enabled: BrowserZoom.larger(than: page.zoom) != nil, page.zoomIn)
        }
        .padding(3)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }

    private func button(_ symbol: String, _ label: String, enabled: Bool, _ change: @escaping () -> Void) -> some View {
        Button { page.zoomPeek.zoom(change) } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 32)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Fades the whole presentation, as no background modifier reaches the system glass behind a
/// sheet; faded out, it lets taps through to the copy of the zoom buttons under it.
private struct BrowserPresentationFade: UIViewRepresentable {
    let hidden: Bool
    let shown: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let controller = sequence(first: view as UIResponder, next: \.next).lazy.compactMap { $0 as? UIViewController }.first
        let levels = controller.map(Self.levels) ?? []
        guard let container = levels.last, (container.alpha == 0) != hidden else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: .beginFromCurrentState) {
            for level in levels { level.alpha = hidden ? 0 : 1 }
        } completion: { _ in
            if !hidden { shown() }
        }
    }

    /// The container, and what the system lays over the presenting view, where a centered sheet
    /// keeps its dimming on iOS 27.
    private static func levels(of controller: UIViewController) -> [UIView] {
        guard let container = controller.presentationController?.containerView else { return [] }
        guard let presenting = controller.presentingViewController?.view, let siblings = presenting.superview?.subviews,
              let index = siblings.firstIndex(of: presenting) else { return [container] }
        return siblings[(index + 1)...] + [container]
    }
}

/// Back, forward and share, for the bottom layout's menu.
private struct BrowserMoreRow: View {
    let page: BrowserPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            tile("chevron.backward", String(localized: "browser_back"), enabled: page.canGoBack) { page.goBack() }
            tile("chevron.forward", String(localized: "browser_forward"), enabled: page.canGoForward) { page.goForward() }
            if let address = page.address {
                ShareLink(item: address) { icon("square.and.arrow.up") }
                    .accessibilityLabel(String(localized: "browser_share"))
            }
        }
    }

    private func tile(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            icon(symbol)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
