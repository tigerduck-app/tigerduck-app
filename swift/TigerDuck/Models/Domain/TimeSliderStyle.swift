import Foundation

enum TimeSliderStyle: String, CaseIterable {
    case fluidTrack
    case segmentedBar

    var displayName: String {
        switch self {
        case .fluidTrack: return "時間軸"
        case .segmentedBar: return "課程區塊"
        }
    }
}
