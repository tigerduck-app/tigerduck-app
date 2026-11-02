import SwiftUI

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
    private static let capsuleHeight: CGFloat = 24
    static let toolbarHeight: CGFloat = 56
    private static let homeIndicatorClearance: CGFloat = 16
    private static let subtitleRoom: CGFloat = 6
    private static let slideTowardCapsule: CGFloat = 56

    private var collapsed: Bool { page.isCollapsed }

    var body: some View {
        switch part {
        case .top: topBar
        case .toolbar: toolbar
        case .bottom: bottomBar
        }
    }


    private var topBar: some View {
        HStack(alignment: .top, spacing: TigerDuckTheme.Spacing.md) {
            closeButton.hiddenWhenCollapsed(collapsed, toward: CGSize(width: Self.slideTowardCapsule, height: -24), moving: !reduceMotion)
            address(subtitle: page.title) {
                HStack(spacing: collapsed ? 3 : 5) {
                    lock(size: collapsed ? 9 : 12)
                    Text(page.host).font(.system(size: collapsed ? 12 : 15, weight: .semibold))
                }
                .offset(y: collapsed || page.title.isEmpty ? 0 : -Self.subtitleRoom)
            }
            circle {
                ShareLink(item: page.address ?? url) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold))
                        .frame(width: Self.barHeight, height: Self.barHeight)
                }
                .accessibilityLabel(String(localized: "browser_share"))
            }
            .hiddenWhenCollapsed(collapsed, toward: CGSize(width: -Self.slideTowardCapsule, height: -24), moving: !reduceMotion)
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

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: TigerDuckTheme.Spacing.md) {
            closeButton.hiddenWhenCollapsed(collapsed, toward: CGSize(width: Self.slideTowardCapsule, height: 24), moving: !reduceMotion)
            address {
                HStack(spacing: 0) {
                    shrinkingIntoCapsule(
                        Button { page.find.start() } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: Self.barHeight)
                                .contentShape(.rect)
                        }
                        .disabled(!page.canUsePage)
                        .accessibilityLabel(String(localized: "browser_find"))
                    )
                    Text(page.host).font(.system(size: collapsed ? 12 : 15, weight: .semibold))
                        .frame(maxWidth: collapsed ? nil : .infinity)
                    shrinkingIntoCapsule(reloadButton(size: 16))
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
            .hiddenWhenCollapsed(collapsed, toward: CGSize(width: -Self.slideTowardCapsule, height: 24), moving: !reduceMotion)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        // Collapsed, the row leaves the safe area for a spot just above the home indicator; the
        // full-height frame reaches the safe area's edge, so it can extend past it.
        .padding(.bottom, collapsed ? Self.homeIndicatorClearance : 0)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.container, edges: collapsed ? .bottom : [])
    }

    private func shrinkingIntoCapsule(_ button: some View) -> some View {
        button.frame(width: collapsed ? 0 : 40, height: collapsed ? 0 : nil)
            .hiddenWhenCollapsed(collapsed, toward: CGSize(width: 0, height: 10), moving: !reduceMotion)
    }

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

    private func address(subtitle: String = "", @ViewBuilder _ label: () -> some View) -> some View {
        Button {
            if collapsed { page.expandChrome() } else { sheet = .address }
        } label: {
            label()
                .lineLimit(1)
                .foregroundStyle(.primary)
                .contentTransition(.interpolate)
                .padding(.horizontal, collapsed ? 11 : 0)
                .frame(maxWidth: collapsed ? nil : .infinity, minHeight: collapsed ? Self.capsuleHeight : Self.barHeight)
                .overlay(alignment: .bottom) { BrowserLoadProgress(page: page) }
                .clipShape(.capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .browserGlass(in: Capsule())
        .contextMenu { BrowserAddressMenu(page: page, sheet: $sheet, onCopy: onCopy) }
        .accessibilityLabel(String(format: String(localized: "browser_address"), page.host))
        .crossFadingInsteadOfMorphing(when: reduceMotion && collapsed)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, Self.subtitleRoom)
                    .opacity(collapsed ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func lock(size: CGFloat) -> some View {
        Image(systemName: "lock.fill").modifier(SymbolSize(size: size)).foregroundStyle(.secondary)
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

/// A symbol's font size as animatable data: SwiftUI swaps a symbol's size in one step while the
/// text beside it interpolates, which shifts the symbol sideways mid-animation.
private nonisolated struct SymbolSize: ViewModifier, Animatable {
    var size: CGFloat

    var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: .semibold))
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

private extension View {
    func crossFadingInsteadOfMorphing(when crossFades: Bool) -> some View {
        id(crossFades).transition(.opacity)
    }
}
