import Defaults
import SwiftUI

struct MoodlePage: Hashable {
    let path: String

    static func forum(cmid: Int) -> MoodlePage { MoodlePage(path: "/mod/forum/view.php?id=\(cmid)") }
    static func discussion(_ id: Int) -> MoodlePage { MoodlePage(path: "/mod/forum/discuss.php?d=\(id)") }
    static func forums(courseId: Int) -> MoodlePage { MoodlePage(path: "/mod/forum/index.php?id=\(courseId)") }
    static func assignments(courseId: Int) -> MoodlePage { MoodlePage(path: "/mod/assign/index.php?id=\(courseId)") }
    static func course(_ id: Int) -> MoodlePage { MoodlePage(path: "/course/view.php?id=\(id)") }
    static func module(_ module: String, cmid: Int) -> MoodlePage { MoodlePage(path: "/mod/\(module)/view.php?id=\(cmid)") }

    var webURL: URL? { URL(string: path, relativeTo: AppConstants.moodleBaseURL)?.absoluteURL }

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

struct MoodleLinkAction {
    fileprivate let open: (URL) -> Void

    func callAsFunction(_ url: URL) { open(url) }
}

extension EnvironmentValues {
    @Entry var openMoodleLink = MoodleLinkAction { _ in }
}

extension View {
    func moodleLinkOpening() -> some View {
        modifier(MoodleLinkOpening())
    }
}

private struct MoodleLinkOpening: ViewModifier {
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.environment(\.openMoodleLink, MoodleLinkAction(open: open))
    }

    private func open(_ url: URL) {
        #if os(iOS)
        // `linkRouting()` opens a Moodle page in the TigerDuck browser, which signs it in.
        openURL(MoodlePage.browserURL(url))
        #else
        if SchoolWeb.isMoodlePage(url) {
            Task { await openURL(MoodlePage.browserURL(url), fallback: nil) }
            return
        }
        openURL(url)
        #endif
    }
}

extension View {
    func moodleListChrome(
        title: String,
        page: MoodlePage?,
        willOpenPage: @escaping () -> Void = {},
        refresh: @escaping () async -> Void
    ) -> some View {
        modifier(MoodleListChrome(title: title, page: page, willOpenPage: willOpenPage, refresh: refresh))
    }

    func moodleArticleChrome(page: MoodlePage? = nil) -> some View {
        modifier(MoodleArticleChrome(page: page))
    }

    func moodleRefreshShortcut(_ refresh: @escaping () async -> Void) -> some View {
        #if os(macOS)
        return background {
            Button("") { Task { await refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        #else
        return self
        #endif
    }
}

private struct MoodleListChrome: ViewModifier {
    let title: String
    let page: MoodlePage?
    let willOpenPage: () -> Void
    let refresh: () async -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if let page {
                    ToolbarItem(placement: .topBarTrailing) { MoodleOpenButton(page: page, willOpen: willOpenPage) }
                }
            }
        #else
        content
            .navigationBarBackButtonHidden(true)
            .safeAreaInset(edge: .top, spacing: 0) {
                MacMoodleTitleBar(title: title) {
                    if let page { MoodleOpenButton(page: page, willOpen: willOpenPage) }
                }
            }
            .moodleRefreshShortcut(refresh)
        #endif
    }
}

private struct MoodleArticleChrome: ViewModifier {
    let page: MoodlePage?

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if let page {
                    ToolbarItem(placement: .topBarTrailing) { MoodleOpenButton(page: page) }
                }
            }
        #else
        content
            .navigationBarBackButtonHidden(true)
            .safeAreaInset(edge: .top, spacing: 0) {
                MacMoodleTitleBar(title: nil) {
                    if let page { MoodleOpenButton(page: page) }
                }
            }
        #endif
    }
}

private struct MoodleOpenButton: View {
    let page: MoodlePage
    var willOpen: () -> Void = {}

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            willOpen()
            Task { await openURL(page) }
        } label: {
            Image(systemName: "arrow.up.right.square")
        }
        .accessibilityLabel(String(localized: "action_open_in_moodle"))
    }
}

#if os(macOS)
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

    static func isNetworkError(_ error: any Error) -> Bool { MoodleFailure.isNetworkError(error) }

    static func message(for error: any Error) -> String { MoodleFailure.message(for: error) }
}

struct MoodleOpenCapsule: View {
    let page: MoodlePage
    var willOpen: () -> Void = {}

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            willOpen()
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

/// A Moodle user as the app names them. NTUST's Moodle spells a full name "student ID @ name",
/// or "name student ID@" in some users' display order; any other full name is the name whole.
/// The backend stores names by the same rule:
/// https://github.com/tigerduck-app/tigerduck-backend/blob/main/server/auth/moodle.py
nonisolated enum MoodlePersonName {
    static func displayName(_ fullName: String) -> String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return parts(of: trimmed)?.name ?? trimmed
    }

    /// The student ID in the full name, for a user whose `idnumber` Moodle leaves out.
    static func studentId(_ fullName: String) -> String? {
        guard let at = fullName.firstIndex(of: "@") else { return nil }
        let id = parts(of: fullName)?.id ?? fullName[..<at].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    private static func parts(of fullName: String) -> (id: String, name: String)? {
        guard let at = fullName.firstIndex(of: "@") else { return nil }
        let before = fullName[..<at].trimmingCharacters(in: .whitespacesAndNewlines)
        let after = fullName[fullName.index(after: at)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !after.isEmpty { return (before, after) }
        // A student ID has digits, so a name that only ends in `@` stays whole.
        guard let space = before.lastIndex(where: \.isWhitespace) else { return nil }
        let id = String(before[before.index(after: space)...])
        let name = before[..<space].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.contains(where: \.isNumber) && !name.isEmpty ? (id, name) : nil
    }
}

struct MoodleAvatar: View {
    let name: String
    let size: CGFloat
    var picture: CGImage?

    var body: some View {
        Group {
            if let picture {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.textSecondary.opacity(0.25))
                    .overlay {
                        Text(name.first.map { String($0) } ?? "")
                            .font(.system(size: size * 0.5, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
