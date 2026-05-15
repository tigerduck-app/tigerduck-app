import SwiftUI

enum ConflictLOrientation {
    case topBarRightTail
    case leftTailBottomBar
}

/// Two interlocking L-shapes that tile the conflict cell without overlap.
///
/// The two inner corners at the bar/tail boundary use matching arcs — same
/// circle, opposite sweep — so Γ and mirror-L meet pixel-perfectly there. When
/// the courses share an outer top/bottom edge (pure overlap), both shapes have
/// a convex corner pointing the same way; rounding both would leave a wedge,
/// so callers set `sharpTopOuter` / `sharpBottomOuter` to keep that edge sharp.
struct ConflictLShape: Shape {
    let orientation: ConflictLOrientation
    var soloAboveFraction: CGFloat = 0
    var soloBelowFraction: CGFloat = 0
    var tailWidthFraction: CGFloat = 0.28
    var outerRadius: CGFloat = 6
    var sharpTopOuter: Bool = false
    var sharpBottomOuter: Bool = false

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = min(outerRadius, min(w, h) / 4)

        let overlapFraction = max(0.01, 1 - soloAboveFraction - soloBelowFraction)
        let overlapTopY = h * soloAboveFraction
        let overlapEndY = h * (soloAboveFraction + overlapFraction)
        let tailW = w * tailWidthFraction

        switch orientation {
        case .topBarRightTail:
            return gammaPath(
                w: w, h: h, r: r, tailW: tailW,
                overlapTopY: overlapTopY, overlapEndY: overlapEndY,
                sharpTopOuter: sharpTopOuter, sharpBottomOuter: sharpBottomOuter
            )
        case .leftTailBottomBar:
            return mirrorLPath(
                w: w, h: h, r: r, tailW: tailW,
                overlapTopY: overlapTopY, overlapEndY: overlapEndY,
                sharpTopOuter: sharpTopOuter, sharpBottomOuter: sharpBottomOuter
            )
        }
    }

    private func gammaPath(
        w: CGFloat, h: CGFloat, r: CGFloat,
        tailW: CGFloat,
        overlapTopY: CGFloat, overlapEndY: CGFloat,
        sharpTopOuter: Bool, sharpBottomOuter: Bool
    ) -> Path {
        let barBottomY = overlapTopY + (overlapEndY - overlapTopY) * 0.5
        let tailLeftX = w - tailW
        let hasSoloAbove = overlapTopY > 0.5
        let hasSoloBelow = overlapEndY < h - 0.5
        let topY: CGFloat = hasSoloAbove ? 0 : overlapTopY
        let bottomY: CGFloat = hasSoloBelow ? h : overlapEndY

        var path = Path()

        if hasSoloAbove {
            path.move(to: CGPoint(x: r, y: 0))
        } else if sharpTopOuter {
            path.move(to: CGPoint(x: tailW, y: overlapTopY))
        } else {
            path.move(to: CGPoint(x: tailW + r, y: overlapTopY))
        }

        path.addLine(to: CGPoint(x: w - r, y: topY))
        path.addRelativeArc(
            center: CGPoint(x: w - r, y: topY + r),
            radius: r,
            startAngle: .degrees(-90),
            delta: .degrees(90)
        )

        path.addLine(to: CGPoint(x: w, y: bottomY - r))
        path.addRelativeArc(
            center: CGPoint(x: w - r, y: bottomY - r),
            radius: r,
            startAngle: .degrees(0),
            delta: .degrees(90)
        )

        if hasSoloBelow {
            path.addLine(to: CGPoint(x: r, y: h))
            path.addRelativeArc(
                center: CGPoint(x: r, y: h - r),
                radius: r,
                startAngle: .degrees(90),
                delta: .degrees(90)
            )
            path.addLine(to: CGPoint(x: 0, y: overlapEndY + r))
            // Convex step-out at (0, overlapEndY)
            path.addRelativeArc(
                center: CGPoint(x: r, y: overlapEndY + r),
                radius: r,
                startAngle: .degrees(180),
                delta: .degrees(90)
            )
            path.addLine(to: CGPoint(x: tailLeftX - r, y: overlapEndY))
            // Concave step at (tailLeftX, overlapEndY)
            path.addRelativeArc(
                center: CGPoint(x: tailLeftX - r, y: overlapEndY - r),
                radius: r,
                startAngle: .degrees(90),
                delta: .degrees(-90)
            )
        } else if sharpBottomOuter {
            path.addLine(to: CGPoint(x: tailLeftX, y: overlapEndY))
        } else {
            path.addLine(to: CGPoint(x: tailLeftX + r, y: overlapEndY))
            path.addRelativeArc(
                center: CGPoint(x: tailLeftX + r, y: overlapEndY - r),
                radius: r,
                startAngle: .degrees(90),
                delta: .degrees(90)
            )
        }

        path.addLine(to: CGPoint(x: tailLeftX, y: barBottomY + r))
        // Concave at (tailLeftX, barBottomY) — matches mirror-L's convex
        path.addRelativeArc(
            center: CGPoint(x: tailLeftX - r, y: barBottomY + r),
            radius: r,
            startAngle: .degrees(0),
            delta: .degrees(-90)
        )

        path.addLine(to: CGPoint(x: tailW + r, y: barBottomY))
        // Convex at (tailW, barBottomY) — matches mirror-L's concave
        path.addRelativeArc(
            center: CGPoint(x: tailW + r, y: barBottomY - r),
            radius: r,
            startAngle: .degrees(90),
            delta: .degrees(90)
        )

        path.addLine(to: CGPoint(x: tailW, y: overlapTopY + r))
        if hasSoloAbove {
            // Concave step at (tailW, overlapTopY)
            path.addRelativeArc(
                center: CGPoint(x: tailW - r, y: overlapTopY + r),
                radius: r,
                startAngle: .degrees(0),
                delta: .degrees(-90)
            )
            path.addLine(to: CGPoint(x: r, y: overlapTopY))
            // Convex step at (0, overlapTopY)
            path.addRelativeArc(
                center: CGPoint(x: r, y: overlapTopY - r),
                radius: r,
                startAngle: .degrees(90),
                delta: .degrees(90)
            )
            path.addLine(to: CGPoint(x: 0, y: r))
            // Top-left cell corner
            path.addRelativeArc(
                center: CGPoint(x: r, y: r),
                radius: r,
                startAngle: .degrees(180),
                delta: .degrees(90)
            )
        } else if sharpTopOuter {
            path.addLine(to: CGPoint(x: tailW, y: overlapTopY))
        } else {
            path.addRelativeArc(
                center: CGPoint(x: tailW + r, y: overlapTopY + r),
                radius: r,
                startAngle: .degrees(180),
                delta: .degrees(90)
            )
        }

        path.closeSubpath()
        return path
    }

    private func mirrorLPath(
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
            // Convex step at (w, overlapTopY)
            path.addRelativeArc(
                center: CGPoint(x: w - r, y: overlapTopY - r),
                radius: r,
                startAngle: .degrees(0),
                delta: .degrees(90)
            )
            path.addLine(to: CGPoint(x: tailRightX + r, y: overlapTopY))
            // Concave step at (tailRightX, overlapTopY)
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
        // Concave at (tailW, barTopY) — matches Γ's convex
        path.addRelativeArc(
            center: CGPoint(x: tailW + r, y: barTopY - r),
            radius: r,
            startAngle: .degrees(180),
            delta: .degrees(-90)
        )

        path.addLine(to: CGPoint(x: barRightX - r, y: barTopY))
        // Convex at (barRightX, barTopY) — matches Γ's concave
        path.addRelativeArc(
            center: CGPoint(x: barRightX - r, y: barTopY + r),
            radius: r,
            startAngle: .degrees(-90),
            delta: .degrees(90)
        )

        path.addLine(to: CGPoint(x: barRightX, y: overlapEndY - r))

        if hasSoloBelow {
            // Concave step at (barRightX, overlapEndY)
            path.addRelativeArc(
                center: CGPoint(x: barRightX + r, y: overlapEndY - r),
                radius: r,
                startAngle: .degrees(180),
                delta: .degrees(-90)
            )
            path.addLine(to: CGPoint(x: w - r, y: overlapEndY))
            // Convex step at (w, overlapEndY)
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
