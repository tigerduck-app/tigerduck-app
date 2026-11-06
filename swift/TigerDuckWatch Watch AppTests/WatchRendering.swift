import SwiftUI
import CoreGraphics

@MainActor
func renderOnWatch(
    _ view: some View, width: CGFloat, height: CGFloat?, locale: Locale = Locale(identifier: "en"),
    truncation: Text.TruncationMode = .tail
) -> CGImage? {
    let framed = view
        .frame(width: width, height: height, alignment: .topLeading)
        .background(.black)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, locale)
        .truncationMode(truncation)
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 2
    return renderer.cgImage
}

func rgbaBytes(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

func inkCount(_ image: CGImage, near color: (red: Int, green: Int, blue: Int), tolerance: Int = 40) -> Int {
    let bytes = rgbaBytes(image)
    return stride(from: 0, to: bytes.count, by: 4).count { i in
        abs(Int(bytes[i]) - color.red) <= tolerance
            && abs(Int(bytes[i + 1]) - color.green) <= tolerance
            && abs(Int(bytes[i + 2]) - color.blue) <= tolerance
    }
}
