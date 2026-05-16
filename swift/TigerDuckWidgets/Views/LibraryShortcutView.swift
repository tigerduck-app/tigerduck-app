import SwiftUI

struct LibraryShortcutView: View {
    let palette: WidgetPalette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.highlight)
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            Text(String(localized: "widget_library_shortcut_title", defaultValue: "Library"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(palette.onSurface)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
