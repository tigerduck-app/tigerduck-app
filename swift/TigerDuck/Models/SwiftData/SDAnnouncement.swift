import Foundation
import SwiftData

@Model
final class SDAnnouncement {
    @Attribute(.unique) var announcementId: String
    var title: String
    var summary: String
    var department: String
    var publishDate: Date
    var detailUrl: String?
    var htmlContent: String?

    init(
        announcementId: String,
        title: String,
        summary: String,
        department: String,
        publishDate: Date,
        detailUrl: String? = nil,
        htmlContent: String? = nil
    ) {
        self.announcementId = announcementId
        self.title = title
        self.summary = summary
        self.department = department
        self.publishDate = publishDate
        self.detailUrl = detailUrl
        self.htmlContent = htmlContent
    }
}
