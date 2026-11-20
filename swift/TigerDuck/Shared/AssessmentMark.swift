import SwiftUI

/// The dashed underline of a class with an assessment, in sRGB, for the app, the widgets and the
/// Live Activity alike.
nonisolated enum AssessmentInk {
    static let light: UInt32 = 0xB4534B
    static let dark: UInt32 = 0xE39A92

    static func hex(isAssessment: Bool, onDark: Bool) -> UInt32? {
        isAssessment ? (onDark ? dark : light) : nil
    }
}

extension Text {
    static func courseName(_ name: String, assessmentInk: Color?) -> Text {
        guard let assessmentInk else { return Text(name) }
        return Text(name)
            .underline(pattern: .dash, color: assessmentInk)
            .accessibilityLabel(Text(verbatim: "\(name), \(String(localized: "course_change_assessment"))"))
    }
}
