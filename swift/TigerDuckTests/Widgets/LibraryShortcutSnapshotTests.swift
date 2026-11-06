#if os(iOS)
import SwiftUI
import Testing
import UIKit
import WidgetKit
@testable import TigerDuck

@MainActor
struct LibraryShortcutSnapshotTests {
    private static let side: CGFloat = 158
    private static let scale: CGFloat = 2
    private static let tintedHomeScreen = UIColor(red: 0.2, green: 0.27, blue: 0.37, alpha: 1)

    @Test(arguments: [ColorScheme.light, .dark], [DynamicTypeSize.large, .accessibility5])
    func fullColor(scheme: ColorScheme, textSize: DynamicTypeSize) throws {
        let palette = Self.palette(scheme, .fullColor)
        let image = try Self.render(palette, scheme, textSize)
        let mode = textSize == .large ? "full" : "full-largest-text"
        Self.picture(image, over: UIColor(palette.background)).saveSnapshot(as: Self.name(mode, scheme))
    }

    /// A tinted or clear Home Screen draws widgets in the accented mode, painting every view white
    /// and keeping only its alpha (Apple's "Optimizing your widget for accented rendering mode and
    /// Liquid Glass"), so the white QR glyph shows only over a square that is not opaque.
    @Test(arguments: [ColorScheme.light, .dark])
    func tinted(scheme: ColorScheme) throws {
        let image = try Self.render(Self.palette(scheme, .accented), scheme)
        let translucent = try Self.alphas(of: image).filter { (0.1..<0.5).contains($0) }
        #expect(translucent.count > 2000)
        Self.picture(image, over: Self.tintedHomeScreen, keepingOnlyAlpha: true)
            .saveSnapshot(as: Self.name("tinted", scheme))
    }

    private static func palette(_ scheme: ColorScheme, _ mode: WidgetRenderingMode) -> WidgetPalette {
        let snapshot = WidgetSnapshot(
            version: 1, generatedAt: Date(timeIntervalSince1970: 0), isLoggedIn: true,
            accentColorHex: 0x007AFF, courses: [], periodTimes: [:], periodOrder: [],
            activeWeekdays: [], activePeriodIds: []
        )
        return WidgetPalette.resolve(snapshot: snapshot, colorScheme: scheme, renderingMode: mode)
    }

    private static func render(
        _ palette: WidgetPalette, _ scheme: ColorScheme, _ textSize: DynamicTypeSize = .large
    ) throws -> CGImage {
        let renderer = ImageRenderer(
            content: LibraryShortcutView(palette: palette)
                .frame(width: side, height: side)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, textSize)
        )
        renderer.scale = scale
        return try #require(renderer.cgImage)
    }

    private static func alphas(of image: CGImage) throws -> [CGFloat] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return context != nil
        }
        try #require(drawn)
        return stride(from: 3, to: bytes.count, by: 4).map { CGFloat(bytes[$0]) / 255 }
    }

    private static func picture(_ image: CGImage, over background: UIColor, keepingOnlyAlpha: Bool = false) -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let content = UIGraphicsImageRenderer(bounds: bounds).image { context in
            UIImage(cgImage: image, scale: scale, orientation: .up).draw(in: bounds)
            if keepingOnlyAlpha {
                UIColor.white.setFill()
                context.fill(bounds, blendMode: .sourceIn)
            }
        }
        return UIGraphicsImageRenderer(bounds: bounds).image { context in
            background.setFill()
            context.fill(bounds)
            content.draw(in: bounds)
        }
    }

    private static func name(_ mode: String, _ scheme: ColorScheme) -> String {
        "library-widget-\(mode)-\(scheme == .dark ? "dark" : "light")-\(Bundle.main.preferredLocalizations.first ?? "")"
    }
}
#endif
