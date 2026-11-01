import SwiftUI

struct ClassTablePersonDialogs: ViewModifier {
    @Bindable var people: ShownPersonModel

    func body(content: Content) -> some View {
        content
            .alert(String(localized: "class_table_rename_title"), isPresented: $people.isRenamingPerson) {
                TextField(String(localized: "class_table_nickname"), text: $people.nicknameDraft)
                Button(String(localized: "action_save")) {
                    people.saveNickname()
                }
                .disabled(!people.canSaveNickname)
                Button(String(localized: "action_cancel"), role: .cancel) {}
            }
            .alert(
                String(
                    format: String(localized: "class_table_delete_user_confirm"),
                    people.personInAlert?.nickname ?? ""
                ),
                isPresented: $people.isDeletingPerson
            ) {
                Button(String(localized: "class_table_delete"), role: .destructive) {
                    people.deletePersonInAlert()
                }
                Button(String(localized: "action_cancel"), role: .cancel) {}
            }
            .alert(String(localized: "class_table_import_lookup_failed"), isPresented: $people.showsLookupFailed) {
                Button(String(localized: "action_confirm"), role: .cancel) {}
            }
            .alert(String(localized: "bulletin_save_failed_title"), isPresented: $people.showsSaveFailed) {
                Button(String(localized: "action_confirm"), role: .cancel) {}
            }
    }
}
