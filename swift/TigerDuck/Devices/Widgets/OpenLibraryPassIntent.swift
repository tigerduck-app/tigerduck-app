import AppIntents
import Foundation

nonisolated enum AppLink {
    static let libraryPass = URL(string: "tigerduck://library")!

    /// iOS hands a Home Screen quick action and an `OpenIntent` to the app outside SwiftUI, where
    /// `onOpenURL` does not reach.
    @MainActor static var open: (URL) -> Void = { _ in }
}

#if os(iOS)
/// iOS brings the app forward and runs an `OpenIntent` there, so the app target compiles this as
/// well as the widget extension whose control names it (Apple's "Creating controls to perform
/// actions across the system").
struct OpenLibraryPassIntent: OpenIntent {
    static let title: LocalizedStringResource = "library_virtual_pass_title"
    static let openAppWhenRun = true

    @Parameter(title: "library_virtual_pass_title", default: .virtualPass)
    var target: LibraryPassScreen

    @MainActor
    func perform() async throws -> some IntentResult {
        AppLink.open(AppLink.libraryPass)
        return .result()
    }
}

nonisolated enum LibraryPassScreen: String, AppEnum {
    case virtualPass

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "library_virtual_pass_title"
    static let caseDisplayRepresentations: [LibraryPassScreen: DisplayRepresentation] = [
        .virtualPass: "library_virtual_pass_title",
    ]
}
#endif
