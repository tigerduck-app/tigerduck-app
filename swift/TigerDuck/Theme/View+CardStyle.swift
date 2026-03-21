import SwiftUI

extension View {
    func cardPadding() -> some View {
        self.padding(TigerDuckTheme.Spacing.lg)
    }

    func sectionSpacing() -> some View {
        self.padding(.vertical, TigerDuckTheme.Spacing.sm)
    }
}
