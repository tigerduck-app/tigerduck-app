import SwiftUI

/// One feature page of the What's New flow: it demos a new feature, and
/// may ask the user about it, before the `whatsnew.json` summary list.
/// Pages are registered per release in ``WhatsNewCatalog``. Build them with
/// the static factories (`.feature`, `.optIn`, `.permission`, `.choice`,
/// `.toggle`, `.custom`), not the memberwise init. Copy is a ``WhatsNewText``
/// in Traditional Chinese and English, not an `app-translation` key. The
/// model builds on every platform; the views that render it
/// (`WhatsNewFlowView`) are iPhone and iPad only.
struct WhatsNewPage: Identifiable {
    /// Stable within its release. Also feeds the sheet identity, so two
    /// pages of one release must not share an id.
    let id: String
    let kind: Kind
    /// Upgrade-flow filter, evaluated when the flow is assembled — e.g.
    /// skip "apply the recommended layout?" for a user who already has
    /// it. Replays from Settings check it too.
    let isApplicable: @MainActor (AppState) -> Bool

    enum Kind {
        /// Demo plus text; the only control is Next.
        case feature(Content)
        /// Confirm runs `apply`; both buttons move on.
        case optIn(Content, confirm: WhatsNewText, decline: WhatsNewText,
                   apply: @MainActor (AppState) -> Void)
        /// Like `optIn`, but confirm awaits `request` — typically a system
        /// permission prompt — before moving on, whatever the answer.
        case permission(Content, confirm: WhatsNewText, decline: WhatsNewText,
                        request: @MainActor (AppState) async -> Void)
        /// Pick between looks. `current` seeds the selection; `select` is
        /// applied live on every tap, so moving on in any way keeps the
        /// last pick.
        case choice(Content, options: [ChoiceOption],
                    current: @MainActor (AppState) -> String,
                    select: @MainActor (AppState, String) -> Void)
        /// A switch under the demo, applied live as it flips.
        case toggle(Content, label: WhatsNewText,
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
        let title: WhatsNewText
        let body: WhatsNewText
    }

    struct ChoiceOption: Identifiable {
        let id: String
        let title: WhatsNewText
        let preview: @MainActor () -> AnyView

        init<Preview: View>(
            id: String,
            title: WhatsNewText,
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
    /// The language the sheet is showing, for the page's own copy.
    let language: WhatsNewLanguage
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
        title: WhatsNewText,
        body: WhatsNewText,
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
        title: WhatsNewText,
        body: WhatsNewText,
        confirm: WhatsNewText,
        decline: WhatsNewText,
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
        title: WhatsNewText,
        body: WhatsNewText,
        confirm: WhatsNewText,
        decline: WhatsNewText,
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
        title: WhatsNewText,
        body: WhatsNewText,
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
        title: WhatsNewText,
        body: WhatsNewText,
        label: WhatsNewText,
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
