import SwiftUI

/// The step before a new person is saved: their nickname and what the share code holds. Import
/// waits on the course lookup.
struct ClassTableImportConfirmView: View {
    @Bindable var model: ClassTableImportModel
    let code: ClassTableShareCode

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "class_table_nickname")) {
                    TextField(String(localized: "class_table_nickname"), text: $model.nickname)
                        #if os(macOS)
                        // A grouped Mac form puts the label beside the field, under the same
                        // words in the section header.
                        .labelsHidden()
                        #endif
                }
                Section {
                    ForEach(ClassTableImportModel.rows(for: code), id: \.title) { row in
                        LabeledContent(row.title, value: row.value)
                    }
                }
            }
            .formStyle(.grouped)
            #if os(macOS)
            // A Mac sheet has no title bar to show the navigation title in.
            .safeAreaInset(edge: .top) {
                Text(String(localized: "class_table_import"))
                    .font(.headline)
                    .padding(.top, TigerDuckTheme.Spacing.lg)
            }
            #endif
            .navigationTitle(String(localized: "class_table_import"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.importPending()
                    } label: {
                        LoadingButtonLabel(isLoading: model.isLookingUp) {
                            Text(String(localized: "action_import")).fontWeight(.semibold)
                        }
                    }
                    .disabled(!model.canImport)
                }
            }
            .classTableImportPrompts(model, onConfirmScreen: true)
        }
        .interactiveDismissDisabled(model.isLookingUp)
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 320)
        #endif
    }
}

extension View {
    /// The import's alerts. Only the screen in front can present one: the confirm screen while
    /// it is up, otherwise the scanner or the Mac class table.
    func classTableImportPrompts(_ model: ClassTableImportModel?, onConfirmScreen: Bool) -> some View {
        modifier(ClassTableImportPrompts(model: model, onConfirmScreen: onConfirmScreen))
    }
}

private struct ClassTableImportPrompts: ViewModifier {
    let model: ClassTableImportModel?
    let onConfirmScreen: Bool

    func body(content: Content) -> some View {
        let prompt = model?.promptShown(onConfirmScreen: onConfirmScreen)
        content.alert(
            prompt?.title ?? "",
            isPresented: Binding(get: { prompt != nil }, set: { if !$0 { model?.dismissPrompt() } }),
            presenting: prompt
        ) { prompt in
            switch prompt {
            case .invalid, .noCode, .ownCode:
                Button(String(localized: "action_confirm"), role: .cancel) {}
            case .replace(let job):
                Button(String(localized: "action_cancel"), role: .cancel) {}
                Button(String(localized: "action_update")) { model?.lookUp(job) }
            case .lookupFailed(let job):
                Button(String(localized: "action_cancel"), role: .cancel) {}
                Button(String(localized: "action_retry")) { model?.lookUp(job) }
            }
        } message: { prompt in
            if let message = prompt.message {
                Text(message)
            }
        }
    }
}
