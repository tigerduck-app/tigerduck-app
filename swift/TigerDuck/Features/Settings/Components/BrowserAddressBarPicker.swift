import SwiftUI

/// The browser's address bar position, picked from two phone sketches with the bar drawn where it goes.
struct BrowserAddressBarPicker: View {
    @Binding var selection: BrowserAddressBar

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.lg) {
            option(.top, String(localized: "browser_address_bar_top"))
            option(.bottom, String(localized: "browser_address_bar_bottom"))
        }
        .padding(.vertical, TigerDuckTheme.Spacing.sm)
    }

    private func option(_ position: BrowserAddressBar, _ label: String) -> some View {
        let isOn = selection == position
        return Button { selection = position } label: {
            VStack(spacing: TigerDuckTheme.Spacing.md) {
                phone(barAtTop: position == .top, isOn: isOn)
                Text(label).foregroundStyle(.primary)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func phone(barAtTop: Bool, isOn: Bool) -> some View {
        let bar = Capsule().fill(.tint).frame(height: 14).padding(.horizontal, 7)
        return VStack(spacing: 6) {
            bar.opacity(barAtTop ? 1 : 0)
            VStack(alignment: .leading, spacing: 6) {
                ForEach([0.7, 0.9, 0.55, 0.8], id: \.self) { width in
                    Capsule().fill(Color(uiColor: .systemFill)).frame(width: 74 * width, height: 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 9)
            .padding(.top, 4)
            bar.opacity(barAtTop ? 0 : 1)
        }
        .padding(.vertical, 6)
        .frame(width: 92, height: 168)
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(uiColor: .separator)), lineWidth: 2)
        }
        .accessibilityHidden(true)
    }
}
