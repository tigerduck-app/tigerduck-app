import Foundation
import SwiftData

@Model
final class SDUserProfile {
    @Attribute(.unique) var studentId: String
    var displayName: String
    var email: String?

    init(studentId: String, displayName: String, email: String? = nil) {
        self.studentId = studentId
        self.displayName = displayName
        self.email = email
    }
}
