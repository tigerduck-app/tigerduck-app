import Defaults
import SwiftUI

/// A page on the Moodle site, opened as every "Open in Moodle" opens one: in the Moodle app where
/// it is installed (on the Mac, where the setting asks for it), else in the browser, signed in
/// through `MoodleAutologinService`.
struct MoodlePage: Hashable {
    /// Site-relative, such as `/mod/forum/view.php?id=5`.
    let path: String

    static func forum(cmid: Int) -> MoodlePage { MoodlePage(path: "/mod/forum/view.php?id=\(cmid)") }
    static func discussion(_ id: Int) -> MoodlePage { MoodlePage(path: "/mod/forum/discuss.php?d=\(id)") }

    var webURL: URL? { URL(string: path, relativeTo: AppConstants.moodleBaseURL)?.absoluteURL }

    /// The link to open, and the one to open when nothing on the device takes it.
    var links: (open: URL?, fallback: URL?) {
        #if os(macOS)
        switch Defaults[.macMoodleOpenTarget] {
        case .app: (AppConstants.moodleDeepLink(redirectingTo: path), webURL)
        case .browser: (webURL, nil)
        }
        #else
        (AppConstants.moodleDeepLink(redirectingTo: path), webURL)
        #endif
    }
}

extension OpenURLAction {
    func callAsFunction(_ page: MoodlePage) async {
        let links = page.links
        guard let url = links.open ?? links.fallback else { return }
        await self(url, fallback: links.open == nil ? nil : links.fallback)
    }
}

/// The status dot of a course's Moodle screens: one source, Moodle.
struct MoodleStatusDot: View {
    let status: ServerStatus
    let isLoading: Bool

    var body: some View {
        SyncStatusDot(
            status: status,
            label: String(localized: "calendar_source_moodle"),
            icon: "graduationcap.fill",
            text: SyncStatusDot.statusText(status),
            isLoading: isLoading
        )
    }
}

extension View {
    /// The bar of a pushed Moodle list: the title, the status dot and "Open in Moodle". On the
    /// Mac the course detail is an overlay in the window, so the bar is drawn in it, not left to
    /// the window's toolbar, and ⌘R runs `refresh`.
    func moodleListChrome(
        title: String,
        status: ServerStatus,
        isLoading: Bool,
        page: MoodlePage?,
        refresh: @escaping () async -> Void
    ) -> some View {
        modifier(MoodleListChrome(title: title, status: status, isLoading: isLoading, page: page, refresh: refresh))
    }

    /// The bar of a pushed Moodle article: the back button alone, over the content.
    func moodleArticleChrome() -> some View {
        modifier(MoodleArticleChrome())
    }
}

private struct MoodleListChrome: ViewModifier {
    let title: String
    let status: ServerStatus
    let isLoading: Bool
    let page: MoodlePage?
    let refresh: () async -> Void

    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if #available(iOS 26, *) {
                    ToolbarItem(placement: .topBarTrailing) { dot }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarTrailing) { dot }
                }
                if let page {
                    ToolbarItem(placement: .topBarTrailing) { openButton(page) }
                }
            }
        #else
        content
            .navigationBarBackButtonHidden(true)
            .safeAreaInset(edge: .top, spacing: 0) {
                MacMoodleTitleBar(title: title) {
                    dot
                    if let page { openButton(page) }
                }
            }
            .background {
                // The class table hands ⌘R over while this screen shows.
                Button("") { Task { await refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        #endif
    }

    private var dot: some View {
        MoodleStatusDot(status: status, isLoading: isLoading)
    }

    private func openButton(_ page: MoodlePage) -> some View {
        Button {
            Task { await openURL(page) }
        } label: {
            Image(systemName: "arrow.up.right.square")
        }
        .accessibilityLabel(String(localized: "action_open_in_moodle"))
    }
}

private struct MoodleArticleChrome: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
        #else
        content
            .navigationBarBackButtonHidden(true)
            .safeAreaInset(edge: .top, spacing: 0) {
                MacMoodleTitleBar(title: nil) { EmptyView() }
            }
        #endif
    }
}

#if os(macOS)
/// The title bar a pushed Moodle screen draws in the course detail overlay.
private struct MacMoodleTitleBar<Trailing: View>: View {
    let title: String?
    @ViewBuilder let trailing: Trailing

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "action_back"))
            if let title {
                Text(title)
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.md)
        .padding(.vertical, TigerDuckTheme.Spacing.sm)
        .background(.bar)
    }
}
#endif

/// A Moodle list with nothing to show yet: a spinner while the first fetch runs, else its error
/// in Moodle's own words and a retry.
struct MoodleFirstLoadView: View {
    let failure: (any Error)?
    let retry: () async -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 36

    var body: some View {
        Group {
            if let failure {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    Image(systemName: Self.isNetworkError(failure) ? "wifi.slash" : "exclamationmark.triangle")
                        .font(.system(size: iconSize))
                        .foregroundStyle(Color.schoolOrange)
                        .accessibilityHidden(true)
                    Text(Self.message(for: failure))
                        .font(TigerDuckTheme.Typography.body)
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "action_retry")) {
                        Task { await retry() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.xl)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    static func isNetworkError(_ error: any Error) -> Bool {
        if case MoodleWebserviceError.transientNetwork = error { return true }
        return error is URLError
    }

    static func message(for error: any Error) -> String {
        isNetworkError(error) ? String(localized: "error_network_unavailable") : error.localizedDescription
    }
}

/// The floating "Open in Moodle" capsule at the foot of a Moodle article, styled as the school
/// bulletin's source button.
struct MoodleOpenCapsule: View {
    let page: MoodlePage

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            Task { await openURL(page) }
        } label: {
            Label(String(localized: "action_open_in_moodle"), systemImage: "arrow.up.right.square")
                .font(.callout.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.vertical, TigerDuckTheme.Spacing.md)
                .background(.tint, in: Capsule())
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}

/// A Moodle user as the app names them. NTUST's Moodle spells a full name "student ID @ name";
/// the part after the `@` is the name, and a name without one is used whole.
nonisolated enum MoodlePersonName {
    static func displayName(_ fullName: String) -> String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return trimmed }
        let name = trimmed[trimmed.index(after: at)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? trimmed : name
    }
}

/// A Moodle user's picture: the first character of their name in a circle.
struct MoodleAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color.textSecondary.opacity(0.25))
            .frame(width: size, height: size)
            .overlay {
                Text(name.first.map { String($0) } ?? "")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
            }
            .accessibilityHidden(true)
    }
}
