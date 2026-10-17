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
    static func forums(courseId: Int) -> MoodlePage { MoodlePage(path: "/mod/forum/index.php?id=\(courseId)") }
    static func assignments(courseId: Int) -> MoodlePage { MoodlePage(path: "/mod/assign/index.php?id=\(courseId)") }
    static func course(_ id: Int) -> MoodlePage { MoodlePage(path: "/course/view.php?id=\(id)") }
    /// A module's page, such as `/mod/resource/view.php?id=5` for the module `resource`.
    static func module(_ module: String, cmid: Int) -> MoodlePage { MoodlePage(path: "/mod/\(module)/view.php?id=\(cmid)") }

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

/// Opens a link from Moodle content where the reader expects it: a Moodle page in the browser
/// signed in, any other web page in the app's browser when the setting asks for it, else as the
/// system opens it. Signing in goes no further than the Moodle site.
struct MoodleLinkAction {
    fileprivate let open: (URL) -> Void

    func callAsFunction(_ url: URL) { open(url) }
}

extension EnvironmentValues {
    @Entry var openMoodleLink = MoodleLinkAction { _ in }
}

extension View {
    /// Set where a screen is pushed, so the screen itself can read ``EnvironmentValues/openMoodleLink``.
    func moodleLinkOpening() -> some View {
        modifier(MoodleLinkOpening())
    }
}

private struct MoodleLinkOpening: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @State private var inAppPage: InAppPage?
    #endif

    func body(content: Content) -> some View {
        content
            .environment(\.openMoodleLink, MoodleLinkAction(open: open))
            #if os(iOS)
            .sheet(item: $inAppPage) { page in
                InAppBrowserView(url: page.url)
                    .ignoresSafeArea()
            }
            #endif
    }

    private func open(_ url: URL) {
        if MoodleAutologinService.isMoodlePage(url) {
            Task { await openURL(MoodlePage.browserURL(url), fallback: nil) }
            return
        }
        #if os(iOS)
        if appState.browserPreference == .inApp, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            inAppPage = InAppPage(url: url)
            return
        }
        #endif
        openURL(url)
    }
}

#if os(iOS)
private struct InAppPage: Identifiable {
    let url: URL
    var id: URL { url }
}
#endif

extension View {
    /// The bar of a pushed Moodle list: the title and "Open in Moodle". On the Mac the course detail
    /// is an overlay in the window, so the bar is drawn in it, not left to the window's toolbar,
    /// and ⌘R runs `refresh`.
    func moodleListChrome(
        title: String,
        page: MoodlePage?,
        willOpenPage: @escaping () -> Void = {},
        refresh: @escaping () async -> Void
    ) -> some View {
        modifier(MoodleListChrome(title: title, page: page, willOpenPage: willOpenPage, refresh: refresh))
    }

    /// The bar of a pushed Moodle article: the back button over the content and "Open in Moodle"
    /// for `page`.
    func moodleArticleChrome(page: MoodlePage? = nil) -> some View {
        modifier(MoodleArticleChrome(page: page))
    }

    /// ⌘R on the Mac for a pushed screen that fetches its own data; the class table hands the
    /// shortcut over while such a screen shows.
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

extension View {
    /// A short note at the top when a refresh fails while the page still shows what it had
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/432); with nothing to show, the
    /// page's `MoodleFirstLoadView` says it instead. `hasContent` is the page's own check, since a
    /// cached value can be one the page does not show.
    func moodleRefreshFailureNote<Value>(
        _ feed: MoodleFeed<Value>,
        hasContent: Bool,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) -> some View {
        modifier(MoodleRefreshFailureNote(
            failureCount: feed.failureCount, failure: feed.failure, hasContent: hasContent, sleep: sleep
        ))
    }
}

/// Whether the refresh-failure note is up, and for how long; the view hands it its events.
@MainActor
@Observable
final class MoodleRefreshFailureNoteModel {
    static let duration: Duration = .seconds(3)

    private(set) var note: MoodleRefreshFailureNote.Note?
    @ObservationIgnored private var isShown = false
    @ObservationIgnored private var notesShown = 0
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void

    init(sleep: @escaping @Sendable (Duration) async -> Void) {
        self.sleep = sleep
    }

    func appeared() { isShown = true }

    func disappeared() {
        isShown = false
        note = nil
    }

    /// Puts up the note for a failed refresh, if it gets one, and returns it.
    func failed(_ failure: (any Error)?, hasContent: Bool) -> MoodleRefreshFailureNote.Note? {
        guard let next = MoodleRefreshFailureNote.note(for: failure, hasContent: hasContent, isShown: isShown) else {
            return nil
        }
        notesShown += 1
        let shown = notesShown
        note = next
        let sleep = sleep
        Task { [weak self] in
            await sleep(Self.duration)
            self?.hide(ifStill: shown)
        }
        return next
    }

    /// Takes down the note once its time is up, unless a later failure put up its own, which
    /// waits for itself. Notes count from 1.
    func hide(ifStill shown: Int) {
        guard notesShown == shown else { return }
        note = nil
    }

    func close() { note = nil }
}

struct MoodleRefreshFailureNote: ViewModifier {
    struct Note: Equatable {
        let text: String
        let symbol: String
    }

    let failureCount: Int
    let failure: (any Error)?
    let hasContent: Bool
    @State private var model: MoodleRefreshFailureNoteModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(failureCount: Int, failure: (any Error)?, hasContent: Bool, sleep: @escaping @Sendable (Duration) async -> Void) {
        self.failureCount = failureCount
        self.failure = failure
        self.hasContent = hasContent
        _model = State(initialValue: MoodleRefreshFailureNoteModel(sleep: sleep))
    }

    /// The note a failed refresh shows: none when the page kept nothing or is off screen, as under
    /// a page pushed over it.
    static func note(for failure: (any Error)?, hasContent: Bool, isShown: Bool) -> Note? {
        guard let failure, hasContent, isShown else { return nil }
        if MoodleFirstLoadView.isNetworkError(failure) {
            return Note(text: String(localized: "error_network_unavailable"), symbol: "wifi.slash")
        }
        if case MoodleWebserviceError.siteMaintenance = failure {
            return Note(text: String(localized: "error_moodle_site_maintenance"), symbol: "exclamationmark.triangle")
        }
        return Note(text: String(localized: "course_moodle_refresh_failed"), symbol: "exclamationmark.triangle")
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ZStack {
                    if let note = model.note {
                        noteButton(note)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy, value: model.note)
            }
            .onAppear { model.appeared() }
            .onDisappear { model.disappeared() }
            .onChange(of: failureCount) { _, _ in
                guard let note = model.failed(failure, hasContent: hasContent) else { return }
                AccessibilityNotification.Announcement(note.text).post()
            }
    }

    private func noteButton(_ note: Note) -> some View {
        Button { model.close() } label: {
            Label {
                Text(note.text)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.leading)
            } icon: {
                Image(systemName: note.symbol).foregroundStyle(Color.schoolOrange)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.vertical, TigerDuckTheme.Spacing.md)
            // A rounded rectangle, not a capsule: a long message wraps, and a capsule's ends cut it.
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.top, TigerDuckTheme.Spacing.sm)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }
}

/// The floating "Open in Moodle" capsule at the foot of a Moodle article, styled as the school
/// bulletin's source button.
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

/// A Moodle user as the app names them. NTUST's Moodle spells a full name "student ID @ name";
/// the part after the `@` is the name, and a name without one is used whole.
nonisolated enum MoodlePersonName {
    static func displayName(_ fullName: String) -> String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return trimmed }
        let name = trimmed[trimmed.index(after: at)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? trimmed : name
    }

    /// The part before the `@`, for a user whose `idnumber` Moodle leaves out.
    static func studentId(_ fullName: String) -> String? {
        guard let at = fullName.firstIndex(of: "@") else { return nil }
        let id = fullName[..<at].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}

/// A user's own picture where the screen has one, else the first character of their name in a
/// circle.
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
