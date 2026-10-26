import Defaults
import SwiftUI
import WebKit

/// TigerDuck's own browser: school pages only, signed in to Moodle, with its chrome in glass
/// over the page. Opens `url` and closes when the browser's data is reset under it.
struct TigerDuckBrowserView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Default(.browserAddressBar) private var addressBar
    @Default(.browserAppearance) private var appearance
    @State private var page = BrowserPage()
    @State private var sheet: BrowserSheet?
    @State private var afterSheet: (() -> Void)?
    @State private var copied = false
    /// The find bar's top edge in the window, which the keyboard under it pushes up.
    @State private var findBarTop: CGFloat?

    private var collapsed: Bool { page.isCollapsed }

    var body: some View {
        BrowserWebView(page: page, start: url, insets: contentInsets, findBarTop: page.find.isActive ? findBarTop : nil, appearance: appearance)
            .ignoresSafeArea(edges: addressBar == .top ? .all : .bottom)
            .overlay { failureView }
            .overlay(alignment: .top) {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    if addressBar == .top { topBar }
                    notice
                }
                .padding(.top, TigerDuckTheme.Spacing.xs)
            }
            .overlay(alignment: .bottom) {
                Group {
                    if page.find.isActive {
                        BrowserFindBar(find: page.find)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { findBarTop = $0 }
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    } else if addressBar == .top {
                        toolbar
                    } else {
                        bottomBar
                    }
                }
            }
            .overlay(alignment: .topLeading) { zoomCopy }
            .animation(motion, value: collapsed)
            .animation(motion, value: page.find.isActive)
            .animation(.default, value: page.signIn.phase)
            .sheet(item: $sheet, onDismiss: {
                afterSheet?()
                afterSheet = nil
            }) { shown in
                BrowserSheetView(page: page, sheet: shown, showsNavigation: addressBar == .bottom) { work in
                    guard sheet != nil else { return }
                    afterSheet = work
                    sheet = nil
                }
            }
            .alert(
                String(localized: "browser_outside_title"),
                isPresented: Binding(get: { page.outside != nil }, set: { if !$0 { page.outside = nil } }),
                presenting: page.outside
            ) { outside in
                Button(String(localized: "browser_open_external")) { UIApplication.shared.open(outside) }
                Button(String(localized: "browser_copy_link")) { UIPasteboard.general.url = outside }
                Button(String(localized: "action_cancel"), role: .cancel) {}
            } message: { outside in
                Text(outside.host(percentEncoded: false) ?? outside.absoluteString)
            }
            .onChange(of: BrowserData.shared.generation, initial: true) { _, now in
                if now != page.generation { dismiss() }
            }
            .onChange(of: page.canUsePage) { _, usable in
                if !usable && page.find.isActive { page.find.end() }
            }
            .onDisappear { page.signIn.close() }
    }

    /// The zoom buttons while a zoom change fades the More sheet, under the sheet's own.
    @ViewBuilder
    private var zoomCopy: some View {
        let peek = page.zoomPeek
        if peek.showsCopy, let frame = peek.frame, peek.size.width > 0 {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                // On the sheet card's color, so they read as they do in the sheet.
                BrowserZoomButtons(page: page)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    .frame(width: peek.size.width, height: peek.size.height)
                    .scaleEffect(frame.width / peek.size.width, anchor: .topLeading)
                    .offset(x: frame.minX - origin.x, y: frame.minY - origin.y)
            }
            .ignoresSafeArea()
        }
    }

    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35) }

    private static let barHeight: CGFloat = 44
    private static let capsuleHeight: CGFloat = 30
    private static let toolbarHeight: CGFloat = 56
    /// From the screen's bottom edge: the home indicator takes about 13 points, and a small gap.
    private static let homeIndicatorClearance: CGFloat = 16
    /// How far a button hidden by the collapse moves toward the address capsule as it fades.
    private static let toCapsule: CGFloat = 56

    private var contentInsets: UIEdgeInsets {
        let gap = TigerDuckTheme.Spacing.lg
        return addressBar == .top
            ? UIEdgeInsets(top: Self.barHeight + gap, left: 0, bottom: Self.toolbarHeight + gap, right: 0)
            : UIEdgeInsets(top: 0, left: 0, bottom: Self.barHeight + gap, right: 0)
    }

    // MARK: - Top layout

    private var topBar: some View {
        HStack(alignment: .top, spacing: TigerDuckTheme.Spacing.md) {
            closeButton.hiddenWhenCollapsed(collapsed, toward: CGSize(width: Self.toCapsule, height: -24), moving: !reduceMotion)
            address {
                VStack(spacing: 0) {
                    HStack(spacing: collapsed ? 4 : 5) {
                        lock(size: collapsed ? 10 : 12)
                        Text(page.host).font(.system(size: collapsed ? 13 : 15, weight: .semibold))
                    }
                    if !collapsed, !page.title.isEmpty {
                        Text(page.title).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            circle {
                ShareLink(item: page.address ?? url) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold))
                        .frame(width: Self.barHeight, height: Self.barHeight)
                }
                .accessibilityLabel(String(localized: "browser_share"))
            }
            .hiddenWhenCollapsed(collapsed, toward: CGSize(width: -Self.toCapsule, height: -24), moving: !reduceMotion)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            toolbarButton("chevron.backward", String(localized: "browser_back"), enabled: page.canGoBack, page.goBack)
            toolbarButton("chevron.forward", String(localized: "browser_forward"), enabled: page.canGoForward, page.goForward)
            reloadButton(size: 21).foregroundStyle(.tint).frame(maxWidth: .infinity)
            toolbarButton("magnifyingglass", String(localized: "browser_find"), enabled: page.canUsePage, page.find.start)
            toolbarButton("ellipsis", String(localized: "browser_more"), enabled: true) { sheet = .more }
        }
        .frame(height: Self.toolbarHeight)
        .browserGlass(in: Capsule())
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .hiddenWhenCollapsed(collapsed, toward: CGSize(width: 0, height: 120), moving: !reduceMotion)
    }

    private func toolbarButton(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: Self.barHeight)
                .contentShape(.rect)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: - Bottom layout

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: TigerDuckTheme.Spacing.md) {
            closeButton.hiddenWhenCollapsed(collapsed, toward: CGSize(width: Self.toCapsule, height: 24), moving: !reduceMotion)
            address {
                HStack(spacing: 0) {
                    intoCapsule(
                        Button { page.find.start() } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: Self.barHeight)
                                .contentShape(.rect)
                        }
                        .disabled(!page.canUsePage)
                        .accessibilityLabel(String(localized: "browser_find"))
                    )
                    Text(page.host).font(.system(size: collapsed ? 13 : 15, weight: .semibold))
                        .frame(maxWidth: collapsed ? nil : .infinity)
                    intoCapsule(reloadButton(size: 16))
                }
            }
            circle {
                Button { sheet = .more } label: {
                    Image(systemName: "ellipsis").font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.tint)
                        .frame(width: Self.barHeight, height: Self.barHeight)
                }
                .accessibilityLabel(String(localized: "browser_more"))
            }
            .hiddenWhenCollapsed(collapsed, toward: CGSize(width: -Self.toCapsule, height: 24), moving: !reduceMotion)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        // Collapsed, the row leaves the safe area for a spot just above the home indicator; the
        // full-height frame reaches the safe area's edge, so it can extend past it.
        .padding(.bottom, collapsed ? Self.homeIndicatorClearance : 0)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.container, edges: collapsed ? .bottom : [])
    }

    /// A button inside the address pill narrows to nothing as the pill shrinks, so it moves with
    /// its own edge of the pill toward the host name and down.
    private func intoCapsule(_ button: some View) -> some View {
        button.frame(width: collapsed ? 0 : 40)
            .hiddenWhenCollapsed(collapsed, toward: CGSize(width: 0, height: 10), moving: !reduceMotion)
    }

    // MARK: - Shared pieces

    private var closeButton: some View {
        circle {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                    .frame(width: Self.barHeight, height: Self.barHeight)
            }
            .accessibilityLabel(String(localized: "browser_close"))
        }
    }

    private func circle(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .foregroundStyle(.primary)
            .browserGlass(in: Circle())
    }

    /// The address pill, which shrinks into the host capsule while the chrome is collapsed. One
    /// element, so the change morphs; with Reduce Motion a new identity cross-fades the two states.
    private func address(@ViewBuilder _ label: () -> some View) -> some View {
        Button {
            if collapsed { page.expandChrome() } else { sheet = .address }
        } label: {
            label()
                .lineLimit(1)
                .foregroundStyle(.primary)
                .contentTransition(.interpolate)
                .padding(.horizontal, collapsed ? 14 : 0)
                .frame(maxWidth: collapsed ? nil : .infinity, minHeight: collapsed ? Self.capsuleHeight : Self.barHeight)
                .overlay(alignment: .bottom) { loadProgress }
                // What fades in or out mid-morph stays inside the capsule as it grows or shrinks.
                .clipShape(.capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .browserGlass(in: Capsule())
        .contextMenu { addressMenu }
        .accessibilityLabel(addressLabel)
        .id(reduceMotion && collapsed)
        .transition(.opacity)
        .frame(maxWidth: .infinity)
    }

    /// Safari's load bar, along the pill's bottom edge in the accent colour while a page loads.
    private var loadProgress: some View {
        ZStack {
            if page.isLoading {
                Rectangle().fill(.tint)
                    .frame(height: 3)
                    .scaleEffect(x: page.progress, anchor: .leading)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: page.progress)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: page.isLoading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var addressMenu: some View {
        Button(String(localized: "browser_copy"), systemImage: "doc.on.doc") {
            UIPasteboard.general.url = page.address
            showCopied()
        }
        if let address = page.address {
            ShareLink(item: address) {
                Label(String(localized: "browser_share"), systemImage: "square.and.arrow.up")
            }
        }
        Button(String(localized: "browser_certificate"), systemImage: "lock") { sheet = .certificate }
    }

    private var addressLabel: String {
        String(format: String(localized: "browser_address"), page.host)
    }

    private func lock(size: CGFloat) -> some View {
        Image(systemName: "lock.fill").font(.system(size: size, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func reloadButton(size: CGFloat) -> some View {
        Button { page.reloadOrStop() } label: {
            Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
                .font(.system(size: size, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: Self.barHeight)
                .contentShape(.rect)
        }
        .accessibilityLabel(page.isLoading ? String(localized: "browser_stop") : String(localized: "browser_reload"))
    }

    // MARK: - Notices

    @ViewBuilder
    private var notice: some View {
        switch page.signIn.phase {
        case .working:
            noticeCapsule {
                ProgressView()
                Text(String(localized: "browser_sign_in_working"))
            }
        case .failed:
            noticeCapsule {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                Text(String(localized: "browser_sign_in_failed_short"))
                Button(String(localized: "action_retry")) { page.signIn.retry() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        case .idle:
            if copied {
                noticeCapsule {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                    Text(String(localized: "browser_copied"))
                }
            }
        }
    }

    private func noticeCapsule(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) { content() }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.leading, TigerDuckTheme.Spacing.lg)
            .padding(.trailing, TigerDuckTheme.Spacing.sm)
            .frame(minHeight: 48)
            .browserGlass(in: Capsule())
            .accessibilityElement(children: .combine)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func showCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }

    @ViewBuilder
    private var failureView: some View {
        if let failure = page.failure {
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                switch failure {
                case .certificate(let host):
                    ContentUnavailableView {
                        Label(String(localized: "browser_error_title"), systemImage: "lock.trianglebadge.exclamationmark")
                    } description: {
                        Text(String(format: String(localized: "browser_error_certificate"), host))
                    }
                case .unreachable(let host):
                    ContentUnavailableView {
                        Label(String(localized: "browser_error_title"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(String(format: String(localized: "browser_error_message"), host))
                    } actions: {
                        Button(String(localized: "action_retry")) { page.reloadOrStop() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}

private extension View {
    func hiddenWhenCollapsed(_ collapsed: Bool, toward offset: CGSize, moving: Bool) -> some View {
        self.offset(collapsed && moving ? offset : .zero)
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let page: BrowserPage
    let start: URL
    let insets: UIEdgeInsets
    let findBarTop: CGFloat?
    let appearance: BrowserAppearance

    func makeCoordinator() -> BrowserNavigator { BrowserNavigator(page: page) }

    func makeUIView(context: Context) -> UIView {
        context.coordinator.makeView(opening: start)
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let webView = container.subviews.compactMap({ $0 as? WKWebView }).last else { return }
        // The page's prefers-color-scheme follows the web view's own style.
        let style: UIUserInterfaceStyle = switch appearance {
        case .automatic: .unspecified
        case .light: .light
        case .dark: .dark
        }
        if webView.overrideUserInterfaceStyle != style { webView.overrideUserInterfaceStyle = style }
        var insets = insets
        if let findBarTop {
            // The find bar and the keyboard under it cover the page from the bar's top edge down.
            let covered = webView.bounds.height - webView.convert(CGPoint(x: 0, y: findBarTop), from: nil).y
            insets.bottom = covered - webView.safeAreaInsets.bottom + TigerDuckTheme.Spacing.lg
        }
        guard webView.scrollView.contentInset != insets else { return }
        webView.scrollView.contentInset = insets
        webView.scrollView.verticalScrollIndicatorInsets = insets
    }
}
