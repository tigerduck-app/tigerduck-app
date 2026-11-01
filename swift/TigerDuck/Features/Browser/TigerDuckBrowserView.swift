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
            .moodleFilePresentation(page.files)
            .overlay { failureView }
            .overlay(alignment: .top) {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    if addressBar == .top { bar(.top) }
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
                        bar(.toolbar)
                    } else {
                        bar(.bottom)
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
            .onChange(of: BrowserData.shared.storeResets, initial: true) { _, now in
                if now != page.storeResets { dismiss() }
            }
            .onChange(of: page.canUsePage) { _, usable in
                if !usable && page.find.isActive { page.find.end() }
            }
            .onDisappear {
                // Quick Look over the browser may take it off screen; the browser stays open under it.
                if page.files.preview == nil { page.signIn.close() }
            }
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

    private func bar(_ part: BrowserBar.Part) -> some View {
        BrowserBar(part: part, page: page, url: url, sheet: $sheet, onCopy: showCopied)
    }

    private var contentInsets: UIEdgeInsets {
        let gap = TigerDuckTheme.Spacing.lg
        return addressBar == .top
            ? UIEdgeInsets(top: BrowserBar.barHeight + gap, left: 0, bottom: BrowserBar.toolbarHeight + gap, right: 0)
            : UIEdgeInsets(top: 0, left: 0, bottom: BrowserBar.barHeight + gap, right: 0)
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
            try? await AppClock.sleep(until: ContinuousClock.now + .seconds(1.4))
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
