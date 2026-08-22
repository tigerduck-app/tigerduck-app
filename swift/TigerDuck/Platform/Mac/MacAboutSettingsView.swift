#if os(macOS)
import SwiftUI

/// About tab — version, build, and the project links.
/// One of the six tabs assembled by `MacSettingsScene`.
struct MacAboutSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(String(localized: "app_name"))
                .font(.title.bold())
            Text(String(format: String(localized: "desktop_about_version_value"), appVersion))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(String(localized: "desktop_about_subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .padding(.top, 8)
            Spacer()
            Text(String(localized: "desktop_about_copyright"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
#endif
