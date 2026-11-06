import SwiftUI
import TigerDuckCore

extension AccentGradient {
    func shapeStyle(color: (Int) -> Color) -> AnyShapeStyle {
        guard isGradient else { return AnyShapeStyle(color(first)) }
        let colors = stops.map(color)
        switch style {
        case .linear:
            return AnyShapeStyle(LinearGradient(colors: colors, startPoint: direction.start, endPoint: direction.end))
        case .radial:
            return AnyShapeStyle(EllipticalGradient(colors: colors))
        case .angular:
            return AnyShapeStyle(AngularGradient(
                colors: colors + [colors[0]], center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)
            ))
        case .mesh:
            if #available(macOS 15, *) {
                return AnyShapeStyle(MeshGradient(width: 3, height: 3, points: Self.meshPoints, colors: meshColors.map(color)))
            }
            return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    /// Controls take a tint's first stop only from a gradient with stops, which a mesh is not.
    func tintStyle(color: (Int) -> Color) -> AnyShapeStyle {
        guard style == .mesh else { return shapeStyle(color: color) }
        var linear = self
        linear.style = .linear
        linear.direction = .topLeftToBottomRight
        return linear.shapeStyle(color: color)
    }

    private static let meshPoints: [SIMD2<Float>] = (0..<9).map { SIMD2(Float($0 % 3) / 2, Float($0 / 3) / 2) }
}

extension AccentGradient.Direction {
    var start: UnitPoint {
        switch self {
        case .leftToRight: UnitPoint(x: 0, y: 0.5)
        case .topLeftToBottomRight: UnitPoint(x: 0, y: 0)
        case .topToBottom: UnitPoint(x: 0.5, y: 0)
        case .topRightToBottomLeft: UnitPoint(x: 1, y: 0)
        case .rightToLeft: UnitPoint(x: 1, y: 0.5)
        case .bottomRightToTopLeft: UnitPoint(x: 1, y: 1)
        case .bottomToTop: UnitPoint(x: 0.5, y: 1)
        case .bottomLeftToTopRight: UnitPoint(x: 0, y: 1)
        }
    }

    var end: UnitPoint {
        UnitPoint(x: 1 - start.x, y: 1 - start.y)
    }
}
