import SwiftUI

enum ConflictLOrientation {
    case topBarRightTail
    case leftTailBottomBar
}

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
            path.addRelativeArc(
                center: CGPoint(x: r, y: overlapEndY + r),
                radius: r,
                startAngle: .degrees(180),
                delta: .degrees(90)
            )
            path.addLine(to: CGPoint(x: tailLeftX - r, y: overlapEndY))
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
        path.addRelativeArc(
            center: CGPoint(x: tailLeftX - r, y: barBottomY + r),
            radius: r,
            startAngle: .degrees(0),
            delta: .degrees(-90)
        )

        path.addLine(to: CGPoint(x: tailW + r, y: barBottomY))
        path.addRelativeArc(
            center: CGPoint(x: tailW + r, y: barBottomY - r),
            radius: r,
            startAngle: .degrees(90),
            delta: .degrees(90)
        )

        path.addLine(to: CGPoint(x: tailW, y: overlapTopY + r))
        if hasSoloAbove {
            path.addRelativeArc(
                center: CGPoint(x: tailW - r, y: overlapTopY + r),
                radius: r,
                startAngle: .degrees(0),
                delta: .degrees(-90)
            )
            path.addLine(to: CGPoint(x: r, y: overlapTopY))
            path.addRelativeArc(
                center: CGPoint(x: r, y: overlapTopY - r),
                radius: r,
                startAngle: .degrees(90),
                delta: .degrees(90)
            )
            path.addLine(to: CGPoint(x: 0, y: r))
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

struct ConflictLaneGeometry {
    let width: CGFloat
    let laneCount: Int
    let cellHeight: CGFloat
    let rowSpacing: CGFloat

    func rect(_ run: ClassTableLaneRun) -> CGRect {
        let laneStep = (width + rowSpacing) / CGFloat(max(laneCount, 1))
        let rowStep = cellHeight + rowSpacing
        return CGRect(
            x: CGFloat(run.lanes.lowerBound) * laneStep,
            y: CGFloat(run.firstRow) * rowStep,
            width: CGFloat(run.lanes.count) * laneStep - rowSpacing,
            height: CGFloat(run.rowCount) * rowStep - rowSpacing
        )
    }
}

struct ConflictLaneShape: Shape {
    let runs: [CGRect]
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard let first = runs.first else { return Path() }
        var strips = [first]
        for run in runs.dropFirst() {
            let above = strips[strips.count - 1]
            let left = max(above.minX, run.minX)
            let right = min(above.maxX, run.maxX)
            if run.minY > above.maxY, right > left {
                strips.append(CGRect(x: left, y: above.maxY, width: right - left, height: run.minY - above.maxY))
            }
            strips.append(run)
        }
        var points: [CGPoint] = []
        for strip in strips {
            points.append(CGPoint(x: strip.maxX, y: strip.minY))
            points.append(CGPoint(x: strip.maxX, y: strip.maxY))
        }
        for strip in strips.reversed() {
            points.append(CGPoint(x: strip.minX, y: strip.maxY))
            points.append(CGPoint(x: strip.minX, y: strip.minY))
        }
        return Self.roundedOutline(through: Self.corners(of: points), radius: cornerRadius)
    }

    static func corners(of points: [CGPoint]) -> [CGPoint] {
        var corners = points
        var changed = true
        while changed, corners.count > 2 {
            changed = false
            for index in corners.indices {
                let previous = corners[(index + corners.count - 1) % corners.count]
                let point = corners[index]
                let next = corners[(index + 1) % corners.count]
                let repeated = point == previous
                let straight = (previous.x == point.x && point.x == next.x) || (previous.y == point.y && point.y == next.y)
                if repeated || straight {
                    corners.remove(at: index)
                    changed = true
                    break
                }
            }
        }
        return corners
    }

    private static func roundedOutline(through corners: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        guard corners.count > 2 else { return path }
        let count = corners.count
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        let last = corners[count - 1]
        path.move(to: CGPoint(x: (last.x + corners[0].x) / 2, y: (last.y + corners[0].y) / 2))
        for index in 0..<count {
            let previous = corners[(index + count - 1) % count]
            let corner = corners[index]
            let next = corners[(index + 1) % count]
            let fitted = min(radius, length(previous, corner) / 2, length(corner, next) / 2)
            path.addArc(tangent1End: corner, tangent2End: next, radius: fitted)
        }
        path.closeSubpath()
        return path
    }
}
