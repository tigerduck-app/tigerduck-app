#if os(macOS)
import SwiftUI

/// Mac-native Settings window (⌘,).
///
/// Mirrors the subset of `AppState` properties that have meaningful Mac
/// equivalents: appearance (accent + preset), language + abbreviation
/// toggles, link-open preference, and — Mac-only — sidebar customisation
/// (which features get pinned and in what order). Push / Live Activity /
/// library settings are intentionally omitted: they're either iOS-only
/// or filtered out for Mac in `AppFeature.macHiddenFeatures`.
///
/// Debug builds additionally surface a Developer tab with the clock
/// override controls so QA can scrub fake time on the Mac the same way
/// they can on iPhone.
struct MacSettingsScene: View {
    var body: some View {
        TabView {
            MacGeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            MacAppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            MacSidebarSettingsView()
                .tabItem { Label("Sidebar", systemImage: "sidebar.left") }
            MacAccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.circle") }
            #if DEBUG
            MacDeveloperSettingsView()
                .tabItem { Label("Developer", systemImage: "hammer") }
            #endif
            MacAboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 580, height: 480)
    }
}

// MARK: - General

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

        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Appearance

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

            Section("Schedule") {
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

// MARK: - Sidebar customisation

/// Pin / unpin / reorder the features that appear in the Mac sidebar.
///
/// Writes straight through to `AppState.configuredTabs` so the change
/// also syncs back to iPhone (the same Defaults-backed list drives both
/// surfaces). Library-related features are filtered out — they don't
/// exist on Mac per `AppFeature.macHiddenFeatures`.
private struct MacSidebarSettingsView: View {
    @Environment(AppState.self) private var appState

    private var pinned: [AppFeature] {
        appState.configuredTabs.filter { $0.isAvailableOnMac }
    }

    private var available: [AppFeature] {
        AppFeature.allCases.filter {
            $0.isImplemented && $0.isAvailableOnMac && !appState.configuredTabs.contains($0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose which features appear in the sidebar and what order they show in. Settings is always available at the bottom of the sidebar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HSplitView {
                section(
                    title: "Pinned",
                    systemImage: "pin.fill",
                    items: pinned,
                    emptyMessage: "Nothing pinned. Add a feature from the right."
                ) { feature, index in
                    pinnedRow(feature, index: index, total: pinned.count)
                }

                section(
                    title: "Available",
                    systemImage: "square.grid.2x2",
                    items: available,
                    emptyMessage: "Every feature is already pinned."
                ) { feature, _ in
                    availableRow(feature)
                }
            }
            .frame(minHeight: 280)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func section<Row: View>(
        title: String,
        systemImage: String,
        items: [AppFeature],
        emptyMessage: String,
        @ViewBuilder row: @escaping (AppFeature, Int) -> Row
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .padding(.leading, 4)
            if items.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.top, 4)
            } else {
                List {
                    ForEach(items.indices, id: \.self) { index in
                        row(items[index], index)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 220)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 240)
    }

    private func pinnedRow(_ feature: AppFeature, index: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            Label(feature.displayName, systemImage: feature.iconName)
            Spacer()
            Button {
                moveUp(at: index)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move up")

            Button {
                moveDown(at: index)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == total - 1)
            .help("Move down")

            Button {
                unpin(feature)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Remove from sidebar")
        }
    }

    private func availableRow(_ feature: AppFeature) -> some View {
        HStack {
            Label(feature.displayName, systemImage: feature.iconName)
            Spacer()
            Button {
                pin(feature)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help("Pin to sidebar")
        }
    }

    private func pin(_ feature: AppFeature) {
        guard !appState.configuredTabs.contains(feature) else { return }
        appState.configuredTabs.append(feature)
    }

    private func unpin(_ feature: AppFeature) {
        appState.configuredTabs.removeAll { $0 == feature }
    }

    private func moveUp(at index: Int) {
        guard index > 0 else { return }
        rearrange { visible in visible.swapAt(index, index - 1) }
    }

    private func moveDown(at index: Int) {
        rearrange { visible in
            guard index < visible.count - 1 else { return }
            visible.swapAt(index, index + 1)
        }
    }

    /// Reorder pinned features one step. `visible` index space; any
    /// cross-platform pins that aren't surfaced on Mac (e.g. a Library
    /// item the user previously pinned on iPhone) ride along unchanged
    /// at the tail so a Mac reorder doesn't disturb iOS-only pins.
    private func rearrange(_ mutate: (inout [AppFeature]) -> Void) {
        var visible = appState.configuredTabs.filter { $0.isAvailableOnMac }
        let hidden = appState.configuredTabs.filter { !$0.isAvailableOnMac }
        mutate(&visible)
        appState.configuredTabs = visible + hidden
    }
}

// MARK: - Account

private struct MacAccountSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("NTUST") {
                if appState.authService.hasStoredCredentials {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Signed in to NTUST SSO")
                    }
                    Button(role: .destructive) {
                        appState.logoutNTUST()
                    } label: {
                        Label("Sign out of NTUST", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Text("Not signed in.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Developer (DEBUG only)

#if DEBUG
/// Mac surface for the debug clock override. Mirrors iPhone's
/// DebugSettingsView, minus the "fake local notification" button —
/// notifications are intentionally absent from the Mac app.
private struct MacDeveloperSettingsView: View {
    @State private var viewModel = MacDebugClockViewModel()

    var body: some View {
        Form {
            Section("Time override") {
                Toggle("Use fake time", isOn: Binding(
                    get: { viewModel.enabled },
                    set: { viewModel.setEnabled($0) }
                ))

                DatePicker(
                    "Date & time",
                    selection: Binding(
                        get: { viewModel.draftInstant },
                        set: { viewModel.setDraftInstant($0) }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .disabled(!viewModel.enabled)

                Picker("Mode", selection: Binding(
                    get: { viewModel.frozen },
                    set: { viewModel.setFrozen($0) }
                )) {
                    Text("Frozen").tag(true)
                    Text("Ticking").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(!viewModel.enabled)
            }

            Section("Effective now") {
                Text(viewModel.effectiveNow.formatted(date: .complete, time: .standard))
                    .font(.system(.body, design: .monospaced))
            }

            Section {
                Text("Time override is mirrored across Home, Class Table, and Calendar. Notifications are disabled on macOS — there is no equivalent of the iPhone fake-push button here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Notes")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.observeEffectiveNow() }
    }
}

@MainActor
@Observable
private final class MacDebugClockViewModel {
    var enabled: Bool
    var draftInstant: Date
    var frozen: Bool
    private(set) var effectiveNow: Date

    init() {
        let current = DebugClockController.shared.currentOverride()
        self.enabled = current != nil
        self.draftInstant = current?.instant ?? Date()
        self.frozen = current?.frozen ?? true
        self.effectiveNow = AppClock.now()
    }

    func observeEffectiveNow() async {
        effectiveNow = AppClock.now()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            effectiveNow = AppClock.now()
        }
    }

    func setEnabled(_ newValue: Bool) {
        enabled = newValue
        if newValue {
            pushOverride()
        } else {
            DebugClockController.shared.setOverride(nil)
        }
    }

    func setDraftInstant(_ newValue: Date) {
        draftInstant = newValue
        if enabled { pushOverride() }
    }

    func setFrozen(_ newValue: Bool) {
        frozen = newValue
        if enabled { pushOverride() }
    }

    private func pushOverride() {
        let override = ClockOverride(
            instant: draftInstant,
            frozen: frozen,
            savedAtReal: Date()
        )
        DebugClockController.shared.setOverride(override)
    }
}
#endif

// MARK: - About

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
