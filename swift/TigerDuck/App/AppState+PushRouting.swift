import SwiftUI
import Defaults

extension AppState {

    #if os(iOS)
    enum DeepLink: Equatable {
        case bulletin(Int)
        case schoolMail(folder: String, uid: UInt32?, uidValidity: UInt32? = nil)
        case assignment(String)
    }

    static func bulletinDeepLink(from userInfo: [AnyHashable: Any]) -> DeepLink? {
        switch userInfo["kind"] as? String {
        case "custom_push_bulletin", "bulletin":
            return pushInteger(from: userInfo["bulletin_id"]).map(DeepLink.bulletin)
        default:
            return nil
        }
    }

    static func remindedAssignment(
        from userInfo: [AnyHashable: Any],
        in assignments: [SDAssignment]
    ) -> SDAssignment? {
        guard userInfo["kind"] as? String == "assignment_reminder",
              let id = pushInteger(from: userInfo["moodle_assignment_id"]) else { return nil }
        return assignments.first { $0.assignmentId == String(id) }
    }

    private static func pushInteger(from raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    static func schoolMailDeepLink(from userInfo: [AnyHashable: Any]) -> DeepLink? {
        guard userInfo["kind"] as? String == MailConstants.notificationKind else { return nil }
        let folder = userInfo["folder"] as? String ?? MailConstants.inbox
        return .schoolMail(folder: folder, uid: schoolMailUID(from: userInfo["uid"]),
                           uidValidity: schoolMailUID(from: userInfo["uidValidity"]))
    }

    private static func schoolMailUID(from raw: Any?) -> UInt32? {
        if let n = raw as? Int { return UInt32(exactly: n) }
        if let n = raw as? NSNumber { return UInt32(exactly: n.int64Value) }
        if let s = raw as? String, let n = Int64(s) { return UInt32(exactly: n) }
        return nil
    }

    struct ServerPopupPayload: Equatable, Identifiable {
        let id: String
        let title: String
        let body: String
    }

    @MainActor
    func isServerPopupShown(_ id: String) -> Bool {
        Defaults[.shownServerPopupIds].contains(id)
    }

    @MainActor
    func markServerPopupShown(_ id: String) {
        var seen = Defaults[.shownServerPopupIds]
        if seen.contains(id) { return }
        seen.append(id)
        if seen.count > 100 {
            seen.removeFirst(seen.count - 100)
        }
        Defaults[.shownServerPopupIds] = seen
    }
    #endif

}
