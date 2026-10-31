import SwiftUI

/// The browser's chrome in glass over the page: the top bar and the toolbar under the page when
/// the address bar is on top, else the one bottom bar.
struct BrowserBar: View {
    enum Part { case top, toolbar, bottom }

    let part: Part
    let page: BrowserPage
    let url: URL
    @Binding var sheet: BrowserSheet?
    let onCopy: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let barHeight: CGFloat = 44
    private static let capsuleHeight: CGFloat = 30
    static let toolbarHeight: CGFloat = 56
    /// From the screen's bottom edge: the home indicator takes about 13 points, and a small gap.
    private static let homeIndicatorClearance: CGFloat = 16
    /// How far a button hidden by the collapse moves toward the address capsule as it fades.
    private static let toCapsule: CGFloat = 56

    private var collapsed: Bool { page.isCollapsed }

    var body: some View {
        switch part {
        case .top: topBar
        case .toolbar: toolbar
        case .bottom: bottomBar
        }
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

    /// A button inside the address pill shrinks to nothing as the pill does, so it moves with its
    /// own edge of the pill toward the host name and down, and leaves the pill its capsule height.
    private func intoCapsule(_ button: some View) -> some View {
        button.frame(width: collapsed ? 0 : 40, height: collapsed ? 0 : nil)
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
                .overlay(alignment: .bottom) { BrowserLoadProgress(page: page) }
                // What fades in or out mid-morph stays inside the capsule as it grows or shrinks.
                .clipShape(.capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .browserGlass(in: Capsule())
        .contextMenu { BrowserAddressMenu(page: page, sheet: $sheet, onCopy: onCopy) }
        .accessibilityLabel(String(format: String(localized: "browser_address"), page.host))
        .id(reduceMotion && collapsed)
        .transition(.opacity)
        .frame(maxWidth: .infinity)
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
}

private extension View {
    func hiddenWhenCollapsed(_ collapsed: Bool, toward offset: CGSize, moving: Bool) -> some View {
        self.offset(collapsed && moving ? offset : .zero)
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
    }
}

/// Safari's load bar, along the pill's bottom edge in the accent colour while a page loads.
private struct BrowserLoadProgress: View {
    let page: BrowserPage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {

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
}

/// The address pill's menu: copy, share and the certificate.
private struct BrowserAddressMenu: View {
    let page: BrowserPage
    @Binding var sheet: BrowserSheet?
    let onCopy: () -> Void

    var body: some View {

            Button(String(localized: "browser_copy"), systemImage: "doc.on.doc") {
                UIPasteboard.general.url = page.address
                onCopy()
            }
            if let address = page.address {
                ShareLink(item: address) {
                    Label(String(localized: "browser_share"), systemImage: "square.and.arrow.up")
                }
            }
            Button(String(localized: "browser_certificate"), systemImage: "lock") { sheet = .certificate }
    }
}
