import Defaults
import SwiftUI

struct AppIconSettingsView: View {
    var host: any AlternateIconHost = UIApplication.shared
    @Default(.appIcon) private var choice
    @State private var isChanging = false

    static let columnCount = 3
    static let iconSize: CGFloat = 76
    private static let ringWidth: CGFloat = 3
    private static let ringGap: CGFloat = 4

    var body: some View {
        List {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: TigerDuckTheme.Spacing.xs, alignment: .top),
                               count: Self.columnCount),
                spacing: TigerDuckTheme.Spacing.xl
            ) {
                ForEach(AppIcon.choices, id: \.self) { icon in
                    cell(icon)
                }
            }
            .padding(.vertical, TigerDuckTheme.Spacing.md)
        }
        .navigationTitle(SettingsRow.appIcon.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func cell(_ icon: AppIcon?) -> some View {
        let isSelected = icon == choice
        let label = String(localized: AppIcon.titleKey(of: icon))
        return Button { choose(icon) } label: {
            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                preview(icon ?? AppIcon.primary(), isSelected: isSelected)
                // One line that shrinks, as the Home Screen labels icons: a third of the width breaks a
                // single word mid-word at the accessibility sizes.
                Text(label)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func preview(_ icon: AppIcon?, isSelected: Bool) -> some View {
        let inset = Self.ringWidth + Self.ringGap
        return (icon?.preview ?? Image(systemName: "app"))
            .resizable()
            .frame(width: Self.iconSize, height: Self.iconSize)
            .padding(inset)
            .overlay {
                // ictool masks a preview with the iOS icon shape, whose corners are about 22.4% of its side.
                RoundedRectangle(cornerRadius: Self.iconSize * 0.224 + inset, style: .continuous)
                    .strokeBorder(.tint, lineWidth: Self.ringWidth)
                    .opacity(isSelected ? 1 : 0)
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .tint)
                        .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)).padding(-2))
                        .offset(x: 4, y: 4)
                }
            }
            .accessibilityHidden(true)
    }

    private func choose(_ icon: AppIcon?) {
        guard !isChanging else { return }
        isChanging = true
        Task {
            await AppIconSwitch.choose(icon, host: host)
            isChanging = false
        }
    }
}
