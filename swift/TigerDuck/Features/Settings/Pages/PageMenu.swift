import SwiftUI

extension View {
    /// Lets the page's ⋯ open `page`'s settings view as a sheet and read their gates.
    func pageMenu(_ page: PageSettings) -> some View {
        modifier(PageMenuHost(page: page))
    }
}

extension EnvironmentValues {
    @Entry var openPageSettings: () -> Void = {}
}

private struct PageMenuHost: ViewModifier {
    let page: PageSettings
    @State private var showsSettings = false

    func body(content: Content) -> some View {
        content
            .environment(\.openPageSettings) { showsSettings = true }
            .settingsEnvironment()
            .sheet(isPresented: $showsSettings) {
                PageSettingsSheet(page: page)
            }
    }
}

private struct PageSettingsSheet: View {
    let page: PageSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            page.view
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "action_done")) { dismiss() }
                    }
                }
        }
    }
}

/// A page's ⋯ when the page has settings to show: in the header beside its `SyncStatusDot`, or
/// in the navigation bar.
struct PageMenuButton<Items: View>: View {
    enum Placement { case header, toolbar }

    let page: PageSettings
    var placement = Placement.header
    var accessibilityLabel = String(localized: "action_more_actions")
    @ViewBuilder let items: () -> Items
    @Environment(\.settingsState) private var state

    var body: some View {
        if page.isShown(in: state) {
            switch placement {
            case .header:
                HeaderMenuButton(accessibilityLabel: accessibilityLabel, items: items)
            case .toolbar:
                Menu(content: items) { Image(systemName: "ellipsis") }
                    .accessibilityLabel(Text(accessibilityLabel))
            }
        }
    }
}

/// The item of a page's ⋯ that opens the page's settings view.
struct FullSettingsButton: View {
    @Environment(\.openPageSettings) private var open

    var body: some View {
        Button(action: open) {
            Label(String(localized: "action_full_settings"), systemImage: "gearshape")
        }
    }
}

/// A switch in a page's ⋯ for one settings row. While the row's gate is closed it is dimmed, with
/// the reason under its label, which a menu shows as the item's subtitle.
struct PageMenuToggle: View {
    let row: SettingsRow
    @Binding var isOn: Bool
    /// What the row's settings page does as the setting turns on, such as asking to notify.
    var onTurnOn: () -> Void = {}
    @Environment(\.settingsState) private var state

    var body: some View {
        let closedReason = row.closedReason(in: state)
        Toggle(isOn: Self.turningOn($isOn, then: onTurnOn)) {
            Text(row.label)
            if let closedReason { Text(closedReason) }
        }
        .disabled(closedReason != nil)
    }

    static func turningOn(_ isOn: Binding<Bool>, then onTurnOn: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isOn.wrappedValue }, set: { newValue in
            let turnsOn = newValue && !isOn.wrappedValue
            isOn.wrappedValue = newValue
            if turnsOn { onTurnOn() }
        })
    }
}
