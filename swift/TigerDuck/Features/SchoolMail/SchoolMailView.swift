#if os(iOS)
import SwiftUI

// Placeholder — the list/detail UI lands in a later task.
struct SchoolMailView: View {
    var embedded: Bool = false

    var body: some View {
        Group {
            if embedded { content } else { NavigationStack { content } }
        }
    }

    private var content: some View {
        EmptyStateView(icon: "envelope", title: String(localized: "feature_school_mail"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.backgroundPrimary)
            .navigationTitle(String(localized: "feature_school_mail"))
    }
}
#endif
