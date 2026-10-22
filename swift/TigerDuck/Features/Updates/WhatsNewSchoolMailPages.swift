#if os(iOS)
import SwiftUI

protocol WhatsNewBottomBarState: AnyObject {
    var configuredTabs: [AppFeature] { get set }
}

extension AppState: WhatsNewBottomBarState {}

extension WhatsNewPage {
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

    static func asksAboutMail(_ state: some WhatsNewBottomBarState) -> Bool {
        recommendedTabsWithMail(state.configuredTabs) != nil
    }

    static func applyMailRecommendation(to state: some WhatsNewBottomBarState) {
        if let tabs = recommendedTabsWithMail(state.configuredTabs) {
            state.configuredTabs = tabs
        }
    }

    static func offersMailPages(configuredTabs: [AppFeature]) -> Bool {
        !configuredTabs.contains(.schoolMail)
    }

    static func recommendedTabsWithMail(_ visible: [AppFeature]) -> [AppFeature]? {
        guard AppFeature.schoolMail.isImplemented, !visible.contains(.schoolMail) else { return nil }
        if let calendar = visible.firstIndex(of: .calendar) {
            var tabs = visible
            tabs[calendar] = .schoolMail
            return tabs
        }
        return visible.count < AppFeature.maxTabs ? visible + [.schoolMail] : nil
    }
}
#endif
