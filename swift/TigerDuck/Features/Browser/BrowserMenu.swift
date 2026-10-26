import Defaults
import SwiftUI

/// The More sheet: the page's zoom, appearance and desktop site, then find in page and print.
/// In the bottom layout it opens with back, forward and share, which have no button there.
struct BrowserMenu: View {
    let page: BrowserPage
    let showsNavigation: Bool
    /// While the zoom changes, all but the zoom buttons fade out, so the page behind shows its new size.
    @Binding var peeking: Bool
    /// Runs its work once the sheet has closed, as print presents a sheet of its own.
    let afterClosing: (@escaping () -> Void) -> Void

    @Default(.browserAppearance) private var appearance
    @State private var peekEnd: Task<Void, Never>?

    static let peekDuration: Duration = .seconds(1.5)
    private static let fade = Animation.easeInOut(duration: 0.25)

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            if showsNavigation { BrowserMoreRow(page: page).opacity(shown) }
            card {
                zoomRow
                VStack(spacing: 0) {
                    Divider().padding(.leading, TigerDuckTheme.Spacing.lg)
                    appearanceRow
                    Divider().padding(.leading, TigerDuckTheme.Spacing.lg)
                    Toggle(String(localized: "browser_desktop_site"), isOn: Binding(
                        get: { page.isDesktopSite },
                        set: { page.setDesktopSite($0) }
                    ))
                    .row()
                }
                .opacity(shown)
            }
            card {
                action("magnifyingglass", String(localized: "browser_find")) { page.find.start() }
                Divider().padding(.leading, 52)
                action("printer", String(localized: "browser_print")) { page.print() }
            }
            .opacity(shown)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.xl)
        .padding(.bottom, TigerDuckTheme.Spacing.lg)
        .onDisappear { peekEnd?.cancel() }
    }

    private var shown: Double { peeking ? 0 : 1 }

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
            Text(String(localized: "browser_zoom")).opacity(shown)
            Spacer(minLength: TigerDuckTheme.Spacing.md)
            HStack(spacing: 4) {
                zoomButton("textformat.size.smaller", String(localized: "browser_zoom_out"),
                           enabled: BrowserZoom.smaller(than: page.zoom) != nil, page.zoomOut)
                Button { zoom(page.resetZoom) } label: {
                    Text((Double(page.zoom) / 100).formatted(.percent))
                        .monospacedDigit()
                        .frame(minWidth: 52)
                }
                .buttonStyle(.plain)
                zoomButton("textformat.size.larger", String(localized: "browser_zoom_in"),
                           enabled: BrowserZoom.larger(than: page.zoom) != nil, page.zoomIn)
            }
            .padding(3)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        }
        .row()
    }

    private func zoomButton(_ symbol: String, _ label: String, enabled: Bool, _ change: @escaping () -> Void) -> some View {
        Button { zoom(change) } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 32)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func zoom(_ change: () -> Void) {
        change()
        withAnimation(Self.fade) { peeking = true }
        peekEnd?.cancel()
        peekEnd = Task {
            try? await Task.sleep(for: Self.peekDuration)
            if !Task.isCancelled { withAnimation(Self.fade) { peeking = false } }
        }
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
            .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(shown), in: RoundedRectangle(cornerRadius: 26))
    }
}

private extension View {
    func row() -> some View {
        padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .frame(minHeight: 52)
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
