#if os(iOS)
import Foundation

enum DeepLink: Equatable {
    case bulletin(Int)
    case schoolMail(folder: String, uid: UInt32?, uidValidity: UInt32? = nil)
    case assignment(String)
}

struct ServerPopupPayload: Equatable, Identifiable {
    let id: String
    let title: String
    let body: String
}

extension DeepLink {
    static func bulletinLink(from userInfo: [AnyHashable: Any]) -> DeepLink? {
        switch userInfo["kind"] as? String {
        case "custom_push_bulletin", "bulletin":
            return pushInteger(from: userInfo["bulletin_id"]).map { .bulletin($0) }
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

    static func schoolMailLink(from userInfo: [AnyHashable: Any]) -> DeepLink? {
        guard userInfo["kind"] as? String == MailConstants.notificationKind else { return nil }
        let folder = userInfo["folder"] as? String ?? MailConstants.inbox
        return .schoolMail(folder: folder, uid: schoolMailUID(from: userInfo["uid"]),
                           uidValidity: schoolMailUID(from: userInfo["uidValidity"]))
    }

    /// `String → Int`: APNs, FCM and relays bridge JSON numbers inconsistently. An int-tagged
    /// NSNumber passes `as? Int`, a Double-tagged one fails it, and some relays send a string.
    private static func pushInteger(from raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    private static func schoolMailUID(from raw: Any?) -> UInt32? {
        if let n = raw as? Int { return UInt32(exactly: n) }
        if let n = raw as? NSNumber { return UInt32(exactly: n.int64Value) }
        if let s = raw as? String, let n = Int64(s) { return UInt32(exactly: n) }
        return nil
    }
}
#endif
