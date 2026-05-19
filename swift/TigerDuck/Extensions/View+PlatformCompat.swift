import SwiftUI

/// Cross-platform shims for view modifiers that only exist on iOS, so the
/// same SwiftUI source compiles for both iPhone and macOS without
/// per-call-site `#if os(iOS)` ladders.
extension View {
    /// `navigationBarTitleDisplayMode(.inline)` on iOS, no-op on macOS.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `textInputAutocapitalization(.never)` on iOS, no-op on macOS.
    @ViewBuilder
    func textFieldNeverCapitalized() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
