import SwiftUI

/// One feature page of the What's New flow — the pages that demo a new
/// feature, and optionally ask the user about it, before the summary
/// list from `whatsnew.json`. Pages are registered per release in
/// ``WhatsNewCatalog``; a user who skipped versions sees every skipped
/// release's pages, oldest first.
///
/// Build pages with the static factories (`.feature`, `.optIn`,
/// `.permission`, `.choice`, `.toggle`, `.custom`) rather than the
/// memberwise init. Text is a localization key resolved through
/// `String(localized:)`, so copy goes through `app-translation` like
/// every other string; a literal with no matching key renders as-is.
///
/// Everything here is model only and builds on every platform; the
/// views that render it are iPhone/iPad-only (`WhatsNewFlowView`).
struct WhatsNewPage: Identifiable {
    /// Stable within its release. Also feeds the sheet identity, so two
    /// pages of one release must not share an id.
    let id: String
    let kind: Kind
    /// Upgrade-flow filter, evaluated when the flow is assembled — e.g.
    /// skip "apply the recommended layout?" for a user who already has
    /// it. Replays from Settings ignore it and show every page.
    let isApplicable: @MainActor (AppState) -> Bool

    enum Kind {
        /// Demo plus text; the only control is Next.
        case feature(Content)
        /// Confirm runs `apply`; both buttons move on.
        case optIn(Content, confirm: String.LocalizationValue, decline: String.LocalizationValue,
                   apply: @MainActor (AppState) -> Void)
        /// Like `optIn`, but confirm awaits `request` — typically a system
        /// permission prompt — before moving on, whatever the answer.
        case permission(Content, confirm: String.LocalizationValue, decline: String.LocalizationValue,
                        request: @MainActor (AppState) async -> Void)
        /// Pick between looks. `current` seeds the selection; `select` is
        /// applied live on every tap, so moving on in any way keeps the
        /// last pick.
        case choice(Content, options: [ChoiceOption],
                    current: @MainActor (AppState) -> String,
                    select: @MainActor (AppState, String) -> Void)
        /// A switch under the demo, applied live as it flips.
        case toggle(Content, label: String.LocalizationValue,
                    get: @MainActor (AppState) -> Bool,
                    set: @MainActor (AppState, Bool) -> Void)
        /// Anything the templates don't cover. The page draws everything
        /// above the page dots; `showsNextButton: false` hands the way
        /// forward to the page itself through ``WhatsNewPageContext/advance``.
        case custom(showsNextButton: Bool, content: @MainActor (WhatsNewPageContext) -> AnyView)
    }

    /// The demo-and-text block every template except `custom` shares.
    struct Content {
        let visual: WhatsNewVisual?
        let title: String.LocalizationValue
        let body: String.LocalizationValue
    }

    struct ChoiceOption: Identifiable {
        let id: String
        let title: String.LocalizationValue
        let preview: @MainActor () -> AnyView

        init<Preview: View>(
            id: String,
            title: String.LocalizationValue,
            @ViewBuilder preview: @escaping @MainActor () -> Preview
        ) {
            self.id = id
            self.title = title
            self.preview = { AnyView(preview()) }
        }
    }

    static let alwaysApplicable: @MainActor (AppState) -> Bool = { _ in true }
}

/// What a `custom` page gets to work with.
struct WhatsNewPageContext {
    let appState: AppState
    /// Moves to the next page, or finishes the flow from the last one.
    let advance: @MainActor () -> Void
}

/// The demo at the top of a page.
enum WhatsNewVisual {
    /// An SF Symbol, animated with a system symbol effect. The cheap path:
    /// no code beyond naming the symbol.
    case symbol(String, effect: WhatsNewSymbolEffect = .bounce)
    /// A hand-built SwiftUI demo, for features worth showing in motion.
    case view(@MainActor () -> AnyView)

    static func custom<Demo: View>(@ViewBuilder _ demo: @escaping @MainActor () -> Demo) -> WhatsNewVisual {
        .view { AnyView(demo()) }
    }
}

/// System SF Symbol effects a symbol demo can loop. All are suppressed
/// under Reduce Motion.
enum WhatsNewSymbolEffect {
    case none, bounce, pulse, wiggle, breathe, rotate, variableColor
}

// MARK: - Factories

extension WhatsNewPage {
    static func feature(
        id: String,
        visual: WhatsNewVisual?,
        title: String.LocalizationValue,
        body: String.LocalizationValue,
        isApplicable: @escaping @MainActor (AppState) -> Bool = alwaysApplicable
    ) -> WhatsNewPage {
        WhatsNewPage(
            id: id,
            kind: .feature(Content(visual: visual, title: title, body: body)),
            isApplicable: isApplicable
        )
    }

    static func optIn(
        id: String,
        visual: WhatsNewVisual?,
        title: String.LocalizationValue,
        body: String.LocalizationValue,
        confirm: String.LocalizationValue,
        decline: String.LocalizationValue,
        isApplicable: @escaping @MainActor (AppState) -> Bool = alwaysApplicable,
        apply: @escaping @MainActor (AppState) -> Void
    ) -> WhatsNewPage {
        WhatsNewPage(
            id: id,
            kind: .optIn(
                Content(visual: visual, title: title, body: body),
                confirm: confirm, decline: decline, apply: apply
            ),
            isApplicable: isApplicable
        )
    }

    static func permission(
        id: String,
        visual: WhatsNewVisual?,
        title: String.LocalizationValue,
        body: String.LocalizationValue,
        confirm: String.LocalizationValue,
        decline: String.LocalizationValue,
        isApplicable: @escaping @MainActor (AppState) -> Bool = alwaysApplicable,
        request: @escaping @MainActor (AppState) async -> Void
    ) -> WhatsNewPage {
        WhatsNewPage(
            id: id,
            kind: .permission(
                Content(visual: visual, title: title, body: body),
                confirm: confirm, decline: decline, request: request
            ),
            isApplicable: isApplicable
        )
    }

    static func choice(
        id: String,
        visual: WhatsNewVisual? = nil,
        title: String.LocalizationValue,
        body: String.LocalizationValue,
        options: [ChoiceOption],
        isApplicable: @escaping @MainActor (AppState) -> Bool = alwaysApplicable,
        current: @escaping @MainActor (AppState) -> String,
        select: @escaping @MainActor (AppState, String) -> Void
    ) -> WhatsNewPage {
        WhatsNewPage(
            id: id,
            kind: .choice(
                Content(visual: visual, title: title, body: body),
                options: options, current: current, select: select
            ),
            isApplicable: isApplicable
        )
    }

    static func toggle(
        id: String,
        visual: WhatsNewVisual?,
        title: String.LocalizationValue,
        body: String.LocalizationValue,
        label: String.LocalizationValue,
        isApplicable: @escaping @MainActor (AppState) -> Bool = alwaysApplicable,
        get: @escaping @MainActor (AppState) -> Bool,
        set: @escaping @MainActor (AppState, Bool) -> Void
    ) -> WhatsNewPage {
        WhatsNewPage(
            id: id,
            kind: .toggle(
                Content(visual: visual, title: title, body: body),
                label: label, get: get, set: set
            ),
            isApplicable: isApplicable
        )
    }

    static func custom<Page: View>(
        id: String,
        showsNextButton: Bool = true,
        isApplicable: @escaping @MainActor (AppState) -> Bool = alwaysApplicable,
        @ViewBuilder content: @escaping @MainActor (WhatsNewPageContext) -> Page
    ) -> WhatsNewPage {
        WhatsNewPage(
            id: id,
            kind: .custom(showsNextButton: showsNextButton, content: { AnyView(content($0)) }),
            isApplicable: isApplicable
        )
    }
}
