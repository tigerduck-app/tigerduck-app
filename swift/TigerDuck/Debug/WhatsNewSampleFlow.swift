#if DEBUG && os(iOS)
import SwiftUI

/// A What's New flow with one page of every template and a summary, for
/// exercising the sheet before any release registers real pages.
/// Presented from `Settings → Developer → Triggers`. The copy is plain
/// English (no keys exist for it, so `String(localized:)` shows it
/// verbatim) and every answer lands in ``WhatsNewSampleState`` — nothing
/// here touches a real setting or a real permission.
enum WhatsNewSampleFlow {
    static func presentation() -> WhatsNewPresentation {
        WhatsNewPresentation(version: "sample", pages: pages, summary: summary)
    }

    private static var pages: [WhatsNewPage] {
        [
            .feature(
                id: "symbol",
                visual: .symbol("envelope.badge", effect: .bounce),
                title: "Feature page",
                body: "An SF Symbol with a looping system effect, plus a few lines about the feature."
            ),
            .feature(
                id: "demo",
                visual: .custom { SampleInboxDemo() },
                title: "Custom demo",
                body: "A SwiftUI scene built from mock pieces of the real screen, animated in place."
            ),
            .choice(
                id: "choice",
                title: "Pick between looks",
                body: "Each card previews one option. A tap applies it straight away.",
                options: [
                    .init(id: "classic", title: "Classic") { SampleLayoutPreview(rows: 3) },
                    .init(id: "compact", title: "Compact") { SampleLayoutPreview(rows: 5) },
                ],
                current: { _ in WhatsNewSampleState.shared.layout },
                select: { _, id in WhatsNewSampleState.shared.layout = id }
            ),
            .toggle(
                id: "toggle",
                visual: .symbol("location.circle", effect: .pulse),
                title: "Toggle page",
                body: "A switch under the demo, applied live as it flips.",
                label: "Show classroom",
                get: { _ in WhatsNewSampleState.shared.isOn },
                set: { _, isOn in WhatsNewSampleState.shared.isOn = isOn }
            ),
            .optIn(
                id: "opt-in",
                visual: .symbol("rectangle.3.group", effect: .wiggle),
                title: "Opt in",
                body: "Confirm applies the change; either button moves on.",
                confirm: "Use the New Layout",
                decline: "Not Now",
                apply: { _ in WhatsNewSampleState.shared.optedIn = true }
            ),
            .permission(
                id: "permission",
                visual: .symbol("bell.badge", effect: .wiggle),
                title: "Ask for permission",
                body: "Confirm waits on a request — here a one-second stand-in for the system prompt.",
                confirm: "Turn On Notifications",
                decline: "Not Now",
                request: { _ in try? await Task.sleep(for: .seconds(1)) }
            ),
            .custom(id: "custom", showsNextButton: false) { context in
                SampleCustomPage(advance: context.advance)
            },
        ]
    }

    private static let summary = WhatsNewRepository.ResolvedWhatsNew(
        version: "sample",
        title: "What's New in TigerDuck",
        items: [
            .init(symbol: "envelope.fill", title: "Summary rows",
                  body: "A symbol, a headline and a line of detail, as Apple's apps lay it out."),
            .init(symbol: "square.stack.3d.up.fill", title: "Stacked pages",
                  body: "Feature pages from every skipped version come first, oldest to newest."),
            .init(symbol: "hand.raised.fill", title: "Swipe down to close",
                  body: "Closing early keeps the current setting for any question not reached."),
            .init(symbol: nil, title: nil,
                  body: "An entry still written as plain highlights renders like this."),
        ]
    )
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
    let advance: () -> Void

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.xl) {
            Spacer(minLength: 0)
            Image(systemName: "wand.and.stars")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Custom page")
                .font(.title.bold())
            Text("Draws everything itself and moves on through its own control.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Continue From the Page", action: advance)
                .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.xl)
    }
}
#endif
