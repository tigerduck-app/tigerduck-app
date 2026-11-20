import SwiftUI

/// UIKit settles every downward drag from a sheet's large detent at its medium one, however fast,
/// and offers no setting for it, so a flick on the content closes the sheet from here instead.
enum SheetFlick {
    /// Points per second downward: a deliberate flick ends well above it, a slow drag well below.
    static let minimumSpeed: CGFloat = 1_200
    /// Points downward, so that a short jerk of the finger closes nothing.
    static let minimumTravel: CGFloat = 40

    static func closesSheet(speed: CGFloat, travel: CGFloat, startedAtTop: Bool, isLarge: Bool) -> Bool {
        isLarge && startedAtTop && speed >= minimumSpeed && travel >= minimumTravel
    }
}

extension View {
    /// Goes on the scroll view at the root of the sheet, whose detent selection is `detent`.
    func flickClosesSheet(at detent: PresentationDetent) -> some View {
        modifier(FlickClosesSheet(isLarge: detent == .large))
    }
}

private struct FlickClosesSheet: ViewModifier {
    let isLarge: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isAtTop = true
    @State private var dragStart: (location: CGPoint, wasAtTop: Bool, wasLarge: Bool)?

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top <= 1 } action: { _, atTop in
                isAtTop = atTop
            }
            // The sheet moves under the finger while UIKit drags it, so only the window's space
            // measures the finger.
            .simultaneousGesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragStart?.location != value.startLocation { dragStart = (value.startLocation, isAtTop, isLarge) }
                    }
                    .onEnded { value in
                        defer { dragStart = nil }
                        guard let dragStart, dragStart.location == value.startLocation else { return }
                        if SheetFlick.closesSheet(
                            speed: value.velocity.height, travel: value.translation.height, startedAtTop: dragStart.wasAtTop,
                            isLarge: dragStart.wasLarge
                        ) {
                            dismiss()
                        }
                    }
            )
    }
}
