import SwiftUI

@Observable
final class Router {
    var homePath = NavigationPath()
    var classTablePath = NavigationPath()
    var calendarPath = NavigationPath()
    var announcementsPath = NavigationPath()
    var morePath = NavigationPath()

    func resetAll() {
        homePath = NavigationPath()
        classTablePath = NavigationPath()
        calendarPath = NavigationPath()
        announcementsPath = NavigationPath()
        morePath = NavigationPath()
    }
}
