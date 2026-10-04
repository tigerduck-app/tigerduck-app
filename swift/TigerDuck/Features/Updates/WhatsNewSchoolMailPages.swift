#if os(iOS)
import SwiftUI

/// The slice of app state the Mail pages read and write: `AppState` in the
/// app, a plain stand-in in tests — which can't build an `AppState`, whose
/// init reaches the Keychain and runs migrations.
protocol WhatsNewBottomBarState: AnyObject {
    var configuredTabs: [AppFeature] { get set }
    var libraryFeatureEnabled: Bool { get }
}

extension AppState: WhatsNewBottomBarState {}

extension WhatsNewPage {
    /// 2.3.0: introduces School Mail, which shipped in 2.2.0 but few
    /// noticed. Says "2.2.0" rather than "the last version" because
    /// someone upgrading from further back sees this page too.
    static let schoolMail = WhatsNewPage.feature(
        id: "school-mail",
        visual: .symbol("envelope.fill", effect: .bounce),
        title: WhatsNewText(
            en: "School Mail is here!",
            zhHant: "校園信箱來了！"
        ),
        body: WhatsNewText(
            en: "Since version 2.2.0, you can read, search and send your NTUST mail right in TigerDuck.",
            zhHant: "從 2.2.0 版開始，可以直接在 TigerDuck 收發、搜尋臺科大信件。"
        ),
        isApplicable: { offersMailPages(configuredTabs: $0.configuredTabs) }
    )

    /// 2.3.0: offers Mail a place in the bottom bar — in Calendar's slot
    /// when the bar has Calendar, otherwise appended just left of More
    /// when there's room. Every other tab stays where it is. Skipped when
    /// Mail is already there or the bar is full without Calendar.
    static let mailInBottomBar = WhatsNewPage.optIn(
        id: "mail-bottom-bar",
        visual: .custom { WhatsNewTabBarChangeDemo { recommendedTabsWithMail($0) ?? $0 } },
        title: WhatsNewText(
            en: "Change the bottom bar to the recommended arrangement?",
            zhHant: "要將底部功能列改為建議的排列嗎？"
        ),
        body: WhatsNewText(
            en: "Mail gets its own tab, one tap away. Anything that moves off the bar stays in More, and you can customize it again anytime in Settings.",
            zhHant: "信箱會有自己的位置，一點就到。移出功能列的項目仍可在「更多」中找到，之後也隨時可以在設定中重新自訂。"
        ),
        confirm: WhatsNewText(en: "Apply Recommended Arrangement", zhHant: "套用建議排列"),
        decline: WhatsNewText(en: "Keep Mine", zhHant: "保留目前設定"),
        isApplicable: { asksAboutMail($0) },
        apply: { applyMailRecommendation(to: $0) }
    )

    /// Whether the bottom-bar question applies to `state`'s bar.
    static func asksAboutMail(_ state: some WhatsNewBottomBarState) -> Bool {
        recommendedTabsWithMail(visibleTabs(state)) != nil
    }

    /// What the question's Apply does: stores the recommended bar, or
    /// leaves the bar alone when there's none — e.g. Back after applying
    /// and Apply again. Keep Mine calls nothing.
    static func applyMailRecommendation(to state: some WhatsNewBottomBarState) {
        if let tabs = recommendedTabsWithMail(visibleTabs(state)) {
            state.configuredTabs = tabs
        }
    }

    /// The Mail pages — the introduction and the bottom-bar question —
    /// are only for a bar without Mail; someone who already put it there
    /// has found it. Mail is never hidden by an opt-in, so the stored list
    /// answers for the bar on screen.
    static func offersMailPages(configuredTabs: [AppFeature]) -> Bool {
        !configuredTabs.contains(.schoolMail)
    }

    /// The bar with Mail added: Calendar's slot taken over when the bar
    /// has Calendar, otherwise Mail appended when there's room. `nil`
    /// when Mail is already there or there's nowhere to put it.
    ///
    /// Works on the bar the user sees, as the tab editor does — a library
    /// tab hidden by the library opt-in neither takes a slot nor survives
    /// the change, the same as the editor's Apply.
    static func recommendedTabsWithMail(_ visible: [AppFeature]) -> [AppFeature]? {
        guard AppFeature.schoolMail.isImplemented, !visible.contains(.schoolMail) else { return nil }
        if let calendar = visible.firstIndex(of: .calendar) {
            var tabs = visible
            tabs[calendar] = .schoolMail
            return tabs
        }
        return visible.count < AppFeature.maxTabs ? visible + [.schoolMail] : nil
    }

    private static func visibleTabs(_ state: some WhatsNewBottomBarState) -> [AppFeature] {
        AppFeature.visibleTabs(state.configuredTabs, libraryEnabled: state.libraryFeatureEnabled)
    }
}
#endif
