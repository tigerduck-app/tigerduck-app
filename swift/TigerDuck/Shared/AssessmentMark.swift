import SwiftUI

/// The dashed underline of a class with an assessment, for the app, the widgets and the Live
/// Activity alike. The inks are sRGB.
nonisolated enum AssessmentInk {
    static let light: UInt32 = 0xA8473F
    static let dark: UInt32 = 0xEFAAA2
    static let dashLength: CGFloat = 4
    static let gapLength: CGFloat = 2
    static let underlineCopyOffsets: [CGFloat] = [0, 0.4, 0.8]
}

/// A course name; with an assessment ink, a dashed line in that ink under each of its lines.
struct CourseName: View {
    let name: String
    let assessmentInk: Color?

    init(_ name: String, assessmentInk: Color?) {
        self.name = name
        self.assessmentInk = assessmentInk
    }

    var body: some View {
        if let assessmentInk {
            // Text.underline takes no width or dash length, and WidgetKit does not list
            // TextRenderer among the views it renders:
            // https://developer.apple.com/documentation/widgetkit/swiftui-views
            ZStack {
                ZStack {
                    ForEach(AssessmentInk.underlineCopyOffsets, id: \.self) { offset in
                        Text(name).foregroundStyle(.clear).underline(color: assessmentInk).offset(y: offset)
                    }
                }
                .mask(AssessmentDashes())
                .accessibilityHidden(true)
                Text(name)
                    .accessibilityLabel(Text(verbatim: "\(name), \(String(localized: "course_change_assessment"))"))
            }
        } else {
            Text(name)
        }
    }
}

private struct AssessmentDashes: Shape {
    func path(in rect: CGRect) -> Path {
        let band = rect.insetBy(dx: 0, dy: -AssessmentInk.dashLength)
        var path = Path()
        for x in stride(from: band.minX, to: band.maxX, by: AssessmentInk.dashLength + AssessmentInk.gapLength) {
            path.addRect(CGRect(x: x, y: band.minY, width: AssessmentInk.dashLength, height: band.height))
        }
        return path
    }
}
