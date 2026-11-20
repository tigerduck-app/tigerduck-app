import SwiftUI

struct HomeFeatureDestination: View {
    let feature: AppFeature

    var body: some View {
        switch feature {
        case .announcements: BulletinsView(embedded: true)
        case .classTable: ClassTableView(embedded: true)
        case .calendar: CalendarTabView(embedded: true)
        case .library: LibraryView(embedded: true)
        case .gpa: ScoreView(embedded: true)
        case .emptyClassroom: EmptyClassroomView(embedded: true)
        default: PlaceholderFeatureView(feature: feature)
        }
    }
}
