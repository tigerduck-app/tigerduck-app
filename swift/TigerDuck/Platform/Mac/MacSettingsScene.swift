#if os(macOS)
import SwiftUI

/// Mac-native Settings window (⌘,).
///
/// Mirrors the subset of `AppState` properties that have meaningful Mac
/// equivalents: appearance (accent + preset), language + abbreviation
/// toggles, link-open preference. Push / Live Activity / library
/// settings are intentionally omitted — they're either iOS-only or
/// filtered out for Mac in `AppFeature.macHiddenFeatures`.
struct MacSettingsScene: View {
    var body: some View {
        TabView {
            MacGeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            MacAppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            MacAboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 420)
    }
}

private struct MacGeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("Language") {
                Picker("App language", selection: $state.appLanguage) {
                    Text("System").tag("system")
                    Text("繁體中文").tag("zh-Hant")
                    Text("English").tag("en")
                }
                .pickerStyle(.menu)
            }

            Section("Course display") {
                Toggle("Use English course abbreviations", isOn: $state.useEnglishCourseAbbreviation)
                Toggle("Use English classroom abbreviations", isOn: $state.useEnglishClassroomAbbreviation)
                Picker("Mandarin classroom display", selection: $state.classroomMandarinDisplay) {
                    Text("Original").tag("original")
                    Text("Pinyin").tag("pinyin")
                    Text("Translated").tag("translated")
                }
                .pickerStyle(.menu)
            }

            Section("Browsing") {
                Picker("Open links in", selection: $state.browserPreference) {
                    ForEach(BrowserPreference.allCases, id: \.self) { pref in
                        Text(pref == .system ? "Default browser" : "In-app browser").tag(pref)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MacAppearanceSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("Accent colour") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(AppState.themeColors, id: \.hex) { entry in
                        accentSwatch(hex: entry.hex)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Visual preset") {
                Picker("Style", selection: $state.visualPreset) {
                    ForEach(VisualPreset.allCases) { preset in
                        Text(preset.id.capitalized).tag(preset)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Schedule") {
                Toggle("Invert slider scroll direction", isOn: $state.invertSliderDirection)
                Toggle("Show absolute assignment due time", isOn: $state.showAbsoluteAssignmentTime)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func accentSwatch(hex: Int) -> some View {
        let color = Color(hex: UInt(bitPattern: Int(hex)))
        let isSelected = appState.accentColorHex == hex
        return Button {
            appState.accentColorHex = hex
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 32, height: 32)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(4)
            .background(
                Circle()
                    .stroke(isSelected ? color : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct MacAboutSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("TigerDuck")
                .font(.title.bold())
            Text("Version \(appVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("National Taiwan University of Science and Technology — community-built companion app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .padding(.top, 8)
            Spacer()
            Text("© TigerDuck contributors. Not affiliated with NTUST.")
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
