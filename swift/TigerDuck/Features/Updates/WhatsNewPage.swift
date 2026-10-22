import SwiftUI

struct WhatsNewPage: Identifiable {
    let id: String
    let kind: Kind
    let isApplicable: @MainActor (AppState) -> Bool

    enum Kind {
        case feature(Content)
        case optIn(Content, confirm: WhatsNewText, decline: WhatsNewText,
                   apply: @MainActor (AppState) -> Void)
        case permission(Content, confirm: WhatsNewText, decline: WhatsNewText,
                        request: @MainActor (AppState) async -> Void)
        case choice(Content, options: [ChoiceOption],
                    current: @MainActor (AppState) -> String,
                    select: @MainActor (AppState, String) -> Void)
        case toggle(Content, label: WhatsNewText,
                    get: @MainActor (AppState) -> Bool,
                    set: @MainActor (AppState, Bool) -> Void)
        case custom(showsNextButton: Bool, content: @MainActor (WhatsNewPageContext) -> AnyView)
    }

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

struct WhatsNewPageContext {
    let appState: AppState
    let language: WhatsNewLanguage
    let advance: @MainActor () -> Void
}

enum WhatsNewVisual {
    case symbol(String, effect: WhatsNewSymbolEffect = .bounce)
    case view(@MainActor () -> AnyView)

    static func custom<Demo: View>(@ViewBuilder _ demo: @escaping @MainActor () -> Demo) -> WhatsNewVisual {
        .view { AnyView(demo()) }
    }
}

enum WhatsNewSymbolEffect {
    case none, bounce, pulse, wiggle, breathe, rotate, variableColor
}

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
