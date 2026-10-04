#if DEBUG && os(iOS)
import SwiftUI

/// A What's New flow with one page of every template and a summary, for
/// exercising the sheet before any release registers real pages.
/// Presented from `Settings → Developer → Triggers`. The copy comes in
/// both of What's New's languages, so switching the app language shows
/// the zh-Hant / English split too; every answer lands in
/// ``WhatsNewSampleState`` — nothing here touches a real setting or a
/// real permission.
enum WhatsNewSampleFlow {
    static func presentation() -> WhatsNewPresentation {
        let language = WhatsNewLanguage.current
        return WhatsNewPresentation(version: "sample", language: language, pages: pages, summary: summary(language))
    }

    private static var pages: [WhatsNewPage] {
        [
            .feature(
                id: "symbol",
                visual: .symbol("envelope.badge", effect: .bounce),
                title: WhatsNewText(en: "Feature page", zhHant: "功能頁"),
                body: WhatsNewText(
                    en: "An SF Symbol with a looping system effect, plus a few lines about the feature.",
                    zhHant: "一個帶有循環系統動畫的 SF Symbol，加上幾行功能說明。"
                )
            ),
            .feature(
                id: "demo",
                visual: .custom { SampleInboxDemo() },
                title: WhatsNewText(en: "Custom demo", zhHant: "自訂示範"),
                body: WhatsNewText(
                    en: "A SwiftUI scene built from mock pieces of the real screen, animated in place.",
                    zhHant: "用真實畫面的模擬元件組成的 SwiftUI 動畫場景。"
                )
            ),
            .choice(
                id: "choice",
                title: WhatsNewText(en: "Pick between looks", zhHant: "選擇外觀"),
                body: WhatsNewText(
                    en: "Each card previews one option. A tap applies it straight away.",
                    zhHant: "每張卡片預覽一個選項，點一下立即套用。"
                ),
                options: [
                    .init(id: "classic", title: WhatsNewText(en: "Classic", zhHant: "經典")) {
                        SampleLayoutPreview(rows: 3)
                    },
                    .init(id: "compact", title: WhatsNewText(en: "Compact", zhHant: "緊湊")) {
                        SampleLayoutPreview(rows: 5)
                    },
                ],
                current: { _ in WhatsNewSampleState.shared.layout },
                select: { _, id in WhatsNewSampleState.shared.layout = id }
            ),
            .toggle(
                id: "toggle",
                visual: .symbol("location.circle", effect: .pulse),
                title: WhatsNewText(en: "Toggle page", zhHant: "開關頁"),
                body: WhatsNewText(
                    en: "A switch under the demo, applied live as it flips.",
                    zhHant: "示範下方的開關，切換時立即生效。"
                ),
                label: WhatsNewText(en: "Show classroom", zhHant: "顯示教室"),
                get: { _ in WhatsNewSampleState.shared.isOn },
                set: { _, isOn in WhatsNewSampleState.shared.isOn = isOn }
            ),
            .optIn(
                id: "opt-in",
                visual: .symbol("rectangle.3.group", effect: .wiggle),
                title: WhatsNewText(en: "Opt in", zhHant: "選擇加入"),
                body: WhatsNewText(
                    en: "Confirm applies the change; either button moves on.",
                    zhHant: "確認會套用變更；兩個按鈕都會前往下一頁。"
                ),
                confirm: WhatsNewText(en: "Use the New Layout", zhHant: "使用新版面"),
                decline: WhatsNewText(en: "Not Now", zhHant: "暫時不要"),
                apply: { _ in WhatsNewSampleState.shared.optedIn = true }
            ),
            .permission(
                id: "permission",
                visual: .symbol("bell.badge", effect: .wiggle),
                title: WhatsNewText(en: "Ask for permission", zhHant: "請求權限"),
                body: WhatsNewText(
                    en: "Confirm waits on a request — here a one-second stand-in for the system prompt.",
                    zhHant: "確認後會等待請求完成——這裡用一秒的等待代替系統提示。"
                ),
                confirm: WhatsNewText(en: "Turn On Notifications", zhHant: "開啟通知"),
                decline: WhatsNewText(en: "Not Now", zhHant: "暫時不要"),
                request: { _ in try? await Task.sleep(for: .seconds(1)) }
            ),
            .custom(id: "custom", showsNextButton: false) { context in
                SampleCustomPage(language: context.language, advance: context.advance)
            },
        ]
    }

    /// Stands in for a `whatsnew.json` entry already resolved to one
    /// locale, the way ``WhatsNewRepository`` hands it over.
    private static func summary(_ language: WhatsNewLanguage) -> WhatsNewRepository.ResolvedWhatsNew {
        func text(_ en: String, _ zhHant: String) -> String {
            WhatsNewText(en: en, zhHant: zhHant).resolved(for: language)
        }
        return WhatsNewRepository.ResolvedWhatsNew(
            version: "sample",
            title: text("What's New in TigerDuck", "TigerDuck 新功能"),
            items: [
                .init(symbol: "envelope.fill",
                      title: text("Summary rows", "摘要列"),
                      body: text("A symbol, a headline and a line of detail, as Apple's apps lay it out.",
                                 "一個符號、一行標題和一行說明，與 Apple 的 App 相同的版面。")),
                .init(symbol: "square.stack.3d.up.fill",
                      title: text("Stacked pages", "累積的頁面"),
                      body: text("Feature pages from every skipped version come first, oldest to newest.",
                                 "略過的每個版本的功能頁會先出現，由舊到新。")),
                .init(symbol: "hand.raised.fill",
                      title: text("Swipe down to close", "向下滑動即可關閉"),
                      body: text("Closing early keeps the current setting for any question not reached.",
                                 "提早關閉時，尚未看到的問題會保留目前的設定。")),
                .init(symbol: nil, title: nil,
                      body: text("An entry still written as plain highlights renders like this.",
                                 "仍以純文字重點撰寫的項目會這樣顯示。")),
            ]
        )
    }
}

/// Where the sample's answers go, so revisiting a page shows the last
/// pick without writing any real setting.
@Observable
final class WhatsNewSampleState {
    static let shared = WhatsNewSampleState()
    var layout = "classic"
    var isOn = false
    var optedIn = false
}

private struct SampleInboxDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleRows = 0

    private let senders = ["Registrar", "Library", "Prof. Lin"]

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            ForEach(Array(senders.enumerated()), id: \.offset) { offset, sender in
                HStack(spacing: TigerDuckTheme.Spacing.md) {
                    Circle().fill(.tint).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sender).font(.subheadline.weight(.semibold))
                        RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 140, height: 6)
                    }
                    Spacer(minLength: 0)
                }
                .padding(TigerDuckTheme.Spacing.md)
                .background(Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous))
                .opacity(offset < visibleRows ? 1 : 0)
                .offset(y: offset < visibleRows || reduceMotion ? 0 : -16)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.xxl)
        .task {
            // Rows drop in one at a time, then the inbox empties and refills.
            while !Task.isCancelled {
                for row in 1...senders.count {
                    try? await Task.sleep(for: .milliseconds(450))
                    withAnimation(.snappy) { visibleRows = row }
                }
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeOut(duration: 0.3)) { visibleRows = 0 }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }
}

private struct SampleLayoutPreview: View {
    let rows: Int

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<rows, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4).fill(.tint.opacity(0.35))
            }
        }
        .padding(TigerDuckTheme.Spacing.md)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

private struct SampleCustomPage: View {
    let language: WhatsNewLanguage
    let advance: () -> Void

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.xl) {
            Spacer(minLength: 0)
            Image(systemName: "wand.and.stars")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(WhatsNewText(en: "Custom page", zhHant: "自訂頁面").resolved(for: language))
                .font(.title.bold())
            Text(WhatsNewText(
                en: "Draws everything itself and moves on through its own control.",
                zhHant: "自己繪製所有內容，並用自己的按鈕前往下一頁。"
            ).resolved(for: language))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(WhatsNewText(en: "Continue From the Page", zhHant: "從頁面繼續").resolved(for: language), action: advance)
                .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.xl)
    }
}
#endif
