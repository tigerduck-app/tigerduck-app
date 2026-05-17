#if os(macOS)
import Foundation

extension AppFeature {
    /// Features deliberately not surfaced in the macOS UI.
    ///
    /// Library lives behind the Library opt-in toggle on iOS and depends on
    /// flows (Discussion Room booking, Lecture sign-up) that haven't been
    /// designed for Mac; surfacing them in the Mac sidebar would create
    /// dead taps. The underlying `LibraryService` still compiles so a
    /// future Mac port can flip the switch without code changes.
    static let macHiddenFeatures: Set<AppFeature> = libraryRelatedFeatures

    /// True iff this feature should be visible anywhere in the macOS UI
    /// (sidebar, More page, future Settings tab pickers).
    var isAvailableOnMac: Bool {
        !Self.macHiddenFeatures.contains(self)
    }
}
#endif
