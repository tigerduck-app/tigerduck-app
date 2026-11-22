import SwiftUI
import TigerDuckCore

struct LibraryShortcutView: View {
    let palette: WidgetPalette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.isFullColor ? palette.highlightFill : AnyShapeStyle(palette.highlightFill.opacity(0.2)))
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            Text(language.string("widget_library_shortcut_title"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(palette.onSurface)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
