import SwiftUI

/// The outline of the conflict's second course: a tail down the left that turns into a bar along
/// the bottom, the mirror of `ConflictLShape`'s top bar and right tail.
enum ConflictMirrorLPath {
    static func path(
        w: CGFloat, h: CGFloat, r: CGFloat,
        tailW: CGFloat,
        overlapTopY: CGFloat, overlapEndY: CGFloat,
        sharpTopOuter: Bool, sharpBottomOuter: Bool
    ) -> Path {
        let barTopY = overlapTopY + (overlapEndY - overlapTopY) * 0.5
        let tailRightX = tailW
        let barRightX = w - tailW
        let hasSoloAbove = overlapTopY > 0.5
        let hasSoloBelow = overlapEndY < h - 0.5
        let topY: CGFloat = hasSoloAbove ? 0 : overlapTopY

        var path = Path()
        path.move(to: CGPoint(x: r, y: topY))

        if hasSoloAbove {
            path.addLine(to: CGPoint(x: w - r, y: 0))
            path.addRelativeArc(
                center: CGPoint(x: w - r, y: r),
                radius: r,
                startAngle: .degrees(-90),
                delta: .degrees(90)
            )
            path.addLine(to: CGPoint(x: w, y: overlapTopY - r))
            path.addRelativeArc(
                center: CGPoint(x: w - r, y: overlapTopY - r),
                radius: r,
                startAngle: .degrees(0),
                delta: .degrees(90)
            )
            path.addLine(to: CGPoint(x: tailRightX + r, y: overlapTopY))
            path.addRelativeArc(
                center: CGPoint(x: tailRightX + r, y: overlapTopY + r),
                radius: r,
                startAngle: .degrees(270),
                delta: .degrees(-90)
            )
        } else if sharpTopOuter {
            path.addLine(to: CGPoint(x: tailRightX, y: overlapTopY))
        } else {
            path.addLine(to: CGPoint(x: tailRightX - r, y: overlapTopY))
            path.addRelativeArc(
                center: CGPoint(x: tailRightX - r, y: overlapTopY + r),
                radius: r,
                startAngle: .degrees(-90),
                delta: .degrees(90)
            )
        }

        path.addLine(to: CGPoint(x: tailW, y: barTopY - r))
        path.addRelativeArc(
            center: CGPoint(x: tailW + r, y: barTopY - r),
            radius: r,
            startAngle: .degrees(180),
            delta: .degrees(-90)
        )

        path.addLine(to: CGPoint(x: barRightX - r, y: barTopY))
        path.addRelativeArc(
            center: CGPoint(x: barRightX - r, y: barTopY + r),
            radius: r,
            startAngle: .degrees(-90),
            delta: .degrees(90)
        )

        path.addLine(to: CGPoint(x: barRightX, y: overlapEndY - r))

        if hasSoloBelow {
            path.addRelativeArc(
                center: CGPoint(x: barRightX + r, y: overlapEndY - r),
                radius: r,
                startAngle: .degrees(180),
                delta: .degrees(-90)
            )
            path.addLine(to: CGPoint(x: w - r, y: overlapEndY))
            path.addRelativeArc(
                center: CGPoint(x: w - r, y: overlapEndY + r),
                radius: r,
                startAngle: .degrees(270),
                delta: .degrees(90)
            )
            path.addLine(to: CGPoint(x: w, y: h - r))
            path.addRelativeArc(
                center: CGPoint(x: w - r, y: h - r),
                radius: r,
                startAngle: .degrees(0),
                delta: .degrees(90)
            )
            path.addLine(to: CGPoint(x: r, y: h))
            path.addRelativeArc(
                center: CGPoint(x: r, y: h - r),
                radius: r,
                startAngle: .degrees(90),
                delta: .degrees(90)
            )
        } else if sharpBottomOuter {
            path.addLine(to: CGPoint(x: barRightX, y: overlapEndY))
            path.addLine(to: CGPoint(x: r, y: overlapEndY))
            path.addRelativeArc(
                center: CGPoint(x: r, y: overlapEndY - r),
                radius: r,
                startAngle: .degrees(90),
                delta: .degrees(90)
            )
        } else {
            path.addRelativeArc(
                center: CGPoint(x: barRightX - r, y: overlapEndY - r),
                radius: r,
                startAngle: .degrees(0),
                delta: .degrees(90)
            )
            path.addLine(to: CGPoint(x: r, y: overlapEndY))
            path.addRelativeArc(
                center: CGPoint(x: r, y: overlapEndY - r),
                radius: r,
                startAngle: .degrees(90),
                delta: .degrees(90)
            )
        }

        path.addLine(to: CGPoint(x: 0, y: topY + r))
        path.addRelativeArc(
            center: CGPoint(x: r, y: topY + r),
            radius: r,
            startAngle: .degrees(180),
            delta: .degrees(90)
        )

        path.closeSubpath()
        return path
    }
}
