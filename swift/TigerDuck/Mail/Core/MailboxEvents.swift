#if os(iOS)
import Foundation

/// What the message and compose screens tell the mail list about the mailbox they share: a read
/// flag changed, a mail left its folder, a folder was recreated, the folder roles moved, or the
/// sent copy of a mail could not be filed.
@MainActor
final class MailboxEvents {
    enum Event: Equatable {
        case seen(folder: String, uid: UInt32, isSeen: Bool)
        case removed(folder: String, uid: UInt32)
        case folderChanged(String)
        case folderRoles([MailFolderRole: String])
        case sentCopyNotice(String)
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
