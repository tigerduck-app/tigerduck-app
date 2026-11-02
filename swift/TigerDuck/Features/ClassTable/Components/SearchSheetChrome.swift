import SwiftUI

extension View {
    /// The bar of a sheet that searches a list: its title, Close at the leading edge, and a search
    /// field kept in the bar with its own Cancel.
    func searchSheetChrome(
        title: String, prompt: String, text: Binding<String>, focused: FocusState<Bool>.Binding
    ) -> some View {
        modifier(SearchSheetChrome(title: title, prompt: prompt, text: text, focused: focused))
    }
}

private struct SearchSheetChrome: ViewModifier {
    let title: String
    let prompt: String
    @Binding var text: String
    let focused: FocusState<Bool>.Binding

    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            // Dismiss the keyboard from the background only: a `.simultaneousGesture` on
            // the list swallows row Buttons. Taps in section gaps reach the background;
            // `.scrollDismissesKeyboard` handles drags.
            .background(
                Color.backgroundPrimary
                    .contentShape(Rectangle())
                    .onTapGesture { focused.wrappedValue = false }
            )
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
            .searchFocused(focused)
            // An active field would otherwise hide the bar that holds Close.
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .autocorrectionDisabled()
            .textFieldNeverCapitalized()
            .navigationTitle(title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
            }
    }
}

/// The searching row and the failure line at the top of a search sheet's list.
struct SearchSheetStatus: View {
    /// The text beside the spinner while a search runs; nil once it ends.
    let searching: String?
    let failure: String?

    var body: some View {
        if let searching {
            Section {
                HStack(spacing: 8) {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text(searching)
                    Spacer()
                }
            }
        }

        if let failure {
            Section {
                Label(failure, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
