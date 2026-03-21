import SwiftUI

extension Animation {
    static let smoothSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let quickSpring = Animation.spring(response: 0.25, dampingFraction: 0.7)
    static let gentleSpring = Animation.spring(response: 0.5, dampingFraction: 0.85)
}
