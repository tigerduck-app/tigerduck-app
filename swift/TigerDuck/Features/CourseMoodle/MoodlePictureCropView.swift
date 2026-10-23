#if os(iOS)
import ImageIO
import SwiftUI
import UIKit

/// Drag and pinch a photo under a circle, which is how the members list and the member page show
/// a picture; the square around the circle is what gets uploaded.
struct MoodlePictureCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onDone: (Data) -> Void

    /// Moodle's largest picture size.
    static let outputSide: CGFloat = 512
    static let maxScale: CGFloat = 5
    static let jpegQuality: CGFloat = 0.85
    /// A few times the output, enough to zoom in, without holding a full camera photo in memory.
    nonisolated static let maxPickedPixels = 2048

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @State private var isDone = false

    var body: some View {
        GeometryReader { geometry in
            let diameter = Self.diameter(in: geometry.size)
            let shownScale = Self.clampedScale(scale * pinch)
            let shownOffset = Self.clampedOffset(offset + drag, imageSize: image.size, diameter: diameter, scale: shownScale)
            let fill = Self.fillSize(image.size, diameter: diameter, scale: shownScale)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: fill.width, height: fill.height)
                    .position(x: center.x + shownOffset.width, y: center.y + shownOffset.height)
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .reverseMask {
                        Circle().frame(width: diameter, height: diameter).position(center)
                    }
                Circle()
                    .stroke(.white.opacity(0.7), lineWidth: 1)
                    .frame(width: diameter, height: diameter)
                    .position(center)
            }
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        scale = Self.clampedScale(scale * value.magnification)
                        offset = Self.clampedOffset(offset, imageSize: image.size, diameter: diameter, scale: scale)
                    }
                    .simultaneously(with: DragGesture()
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            offset = Self.clampedOffset(offset + value.translation, imageSize: image.size,
                                                        diameter: diameter, scale: scale)
                        })
            )
            .onChange(of: geometry.size) {
                offset = Self.clampedOffset(offset, imageSize: image.size, diameter: diameter, scale: scale)
            }
            .overlay(alignment: .bottom) {
                HStack {
                    Button(String(localized: "action_cancel"), action: onCancel)
                    Spacer()
                    Button(String(localized: "action_done")) {
                        let rect = Self.cropRect(imageSize: image.size, diameter: diameter, scale: scale, offset: offset)
                        guard !isDone, let jpeg = Self.jpeg(image, cropping: rect) else { return }
                        isDone = true
                        onDone(jpeg)
                    }
                    .fontWeight(.semibold)
                    .disabled(isDone)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, TigerDuckTheme.Spacing.xl)
                .padding(.bottom, TigerDuckTheme.Spacing.lg)
            }
        }
        .clipped()
        .background(.black)
        .ignoresSafeArea(edges: .horizontal)
    }

    static func diameter(in size: CGSize) -> CGFloat {
        max(min(size.width, size.height) - 2 * TigerDuckTheme.Spacing.xl, 1)
    }

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, 1), maxScale)
    }

    /// The photo's size on screen: at scale 1 its shorter side spans the circle.
    static func fillSize(_ imageSize: CGSize, diameter: CGFloat, scale: CGFloat) -> CGSize {
        let factor = diameter * scale / max(min(imageSize.width, imageSize.height), 1)
        return CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
    }

    /// Keeps the circle covered by the photo.
    static func clampedOffset(_ offset: CGSize, imageSize: CGSize, diameter: CGFloat, scale: CGFloat) -> CGSize {
        let fill = fillSize(imageSize, diameter: diameter, scale: scale)
        let limitX = max((fill.width - diameter) / 2, 0)
        let limitY = max((fill.height - diameter) / 2, 0)
        return CGSize(width: min(max(offset.width, -limitX), limitX), height: min(max(offset.height, -limitY), limitY))
    }

    /// The square under the circle, in the image's own coordinates.
    static func cropRect(imageSize: CGSize, diameter: CGFloat, scale: CGFloat, offset: CGSize) -> CGRect {
        let side = min(imageSize.width, imageSize.height) / scale
        let perPoint = side / diameter
        return CGRect(
            x: imageSize.width / 2 - offset.width * perPoint - side / 2,
            y: imageSize.height / 2 - offset.height * perPoint - side / 2,
            width: side,
            height: side
        )
    }

    /// A picked photo decoded at ``maxPickedPixels`` at most and turned upright.
    nonisolated static func downsampled(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPickedPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Transparent parts come out white, not JPEG's black.
    static func jpeg(_ image: UIImage, cropping rect: CGRect) -> Data? {
        guard rect.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let side = CGSize(width: outputSide, height: outputSide)
        let factor = outputSide / rect.width
        let renderer = UIGraphicsImageRenderer(size: side, format: format)
        return renderer.jpegData(withCompressionQuality: jpegQuality) { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: side))
            image.draw(in: CGRect(x: -rect.minX * factor, y: -rect.minY * factor,
                                  width: image.size.width * factor, height: image.size.height * factor))
        }
    }
}

private extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}

private extension View {
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle().overlay { mask().blendMode(.destinationOut) }.compositingGroup()
        }
    }
}
#endif
