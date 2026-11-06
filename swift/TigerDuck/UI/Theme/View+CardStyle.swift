import SwiftUI

extension View {
    func cardPadding() -> some View {
        self.padding(TigerDuckTheme.Spacing.lg)
    }
}

extension View {
    func centeredListRow() -> some View {
        frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }
}
