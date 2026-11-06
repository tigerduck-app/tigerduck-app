#if os(iOS)
import Foundation

@MainActor
final class MailboxEvents {
    enum Event: Equatable {
        case seen(folder: String, uid: UInt32, isSeen: Bool)
        case removed(folder: String, uid: UInt32)
        case folderChanged(String)
        case folderRoles([MailFolderRole: String])
        case sentCopyNotice(String)
        case draftHidden(MailListRow.ID, isHidden: Bool)
    }

    private var observers: [(Event) -> Void] = []

    func observe(_ observer: @escaping (Event) -> Void) {
        observers.append(observer)
    }

    func post(_ event: Event) {
        for observer in observers { observer(event) }
    }
}
#endif
