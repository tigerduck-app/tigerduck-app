#if os(macOS)
import AppKit
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
                .tabItem { Label(String(localized: "mac_settings_tab_general"), systemImage: "gearshape") }
            MacAppearanceSettingsView()
                .tabItem { Label(String(localized: "mac_settings_tab_appearance"), systemImage: "paintpalette") }
            MacSidebarSettingsView()
                .tabItem { Label(String(localized: "mac_settings_tab_sidebar"), systemImage: "sidebar.left") }
            MacAccountSettingsView()
                .tabItem { Label(String(localized: "settings_section_account"), systemImage: "person.circle") }
            #if DEBUG
            MacDeveloperSettingsView()
                .tabItem { Label("Developer", systemImage: "hammer") }
            #endif
            MacAboutSettingsView()
                .tabItem { Label(String(localized: "settings_section_about"), systemImage: "info.circle") }
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
            Section(String(localized: "mac_settings_section_interface")) {
                Picker(String(localized: "settings_language"), selection: $state.appLanguage) {
                    Text(String(localized: "settings_language_follow_system")).tag("system")
                    Text(String(localized: "settings_language_traditional_chinese")).tag("zh-Hant")
                    Text(String(localized: "settings_language_english")).tag("en")
                }
                .pickerStyle(.menu)
            }

            Section(String(localized: "mac_settings_section_course_display")) {
                Toggle(String(localized: "settings_use_english_course_abbreviation"), isOn: $state.useEnglishCourseAbbreviation)
                Toggle(String(localized: "settings_use_english_classroom_abbreviation"), isOn: $state.useEnglishClassroomAbbreviation)
                Picker(String(localized: "settings_classroom_mandarin_display"), selection: $state.classroomMandarinDisplay) {
                    Text(String(localized: "settings_classroom_mandarin_display_original")).tag("original")
                    Text(String(localized: "settings_classroom_mandarin_display_pinyin")).tag("pinyin")
                    Text(String(localized: "settings_classroom_mandarin_display_translated")).tag("translated")
                }
                .pickerStyle(.menu)
            }

            Section(String(localized: "mac_settings_section_links")) {
                // No first-party Moodle Mac app exists, but the iPad
                // Moodle app installed via Mac App Store registers
                // `moodlemobile://`, so users who chose to install it can
                // opt into the deep link. Default stays `.browser` —
                // sending the user to `moodlemobile://` with no app
                // installed yields "no app handles this URL".
                Picker(String(localized: "mac_settings_moodle_open_in"), selection: $state.macMoodleOpenTarget) {
                    Text(String(localized: "mac_settings_moodle_open_in_browser")).tag(MoodleOpenTarget.browser)
                    Text(String(localized: "mac_settings_moodle_open_in_app")).tag(MoodleOpenTarget.app)
                }
                .pickerStyle(.menu)
            }

            // Mirror of the iPhone language redirect: the per-app
            // Language & Region pane in System Settings is where macOS
            // actually applies the system locale. Re-uses the iPhone
            // keys (`feature_category_language`, `settings_language`) so
            // we don't fork translations for the same idea.
            Section(String(localized: "feature_category_language")) {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text(String(localized: "settings_language"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
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
            Section(String(localized: "settings_accent_color")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(AppState.themeColors, id: \.hex) { entry in
                        accentSwatch(hex: entry.hex)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(String(localized: "mac_settings_section_schedule")) {
                Toggle(String(localized: "settings_show_absolute_assignment_time"), isOn: $state.showAbsoluteAssignmentTime)
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
/// Writes straight through to `AppState.macConfiguredTabs`, which is a
/// Mac-only preference. The iOS tab bar uses `configuredTabs` and is
/// capped at four user tabs — Mac sidebar edits must not leak into it.
/// Library-related features are filtered out — they don't exist on Mac
/// per `AppFeature.macHiddenFeatures`.
private struct MacSidebarSettingsView: View {
    @Environment(AppState.self) private var appState

    private var pinned: [AppFeature] {
        appState.macConfiguredTabs.filter { $0.isAvailableOnMac }
    }

    private var available: [AppFeature] {
        AppFeature.allCases.filter {
            $0.isImplemented && $0.isAvailableOnMac && !appState.macConfiguredTabs.contains($0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "mac_settings_sidebar_description"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HSplitView {
                section(
                    title: String(localized: "mac_settings_sidebar_pinned"),
                    systemImage: "pin.fill",
                    items: pinned,
                    emptyMessage: String(localized: "mac_settings_sidebar_empty_pinned")
                ) { feature, index in
                    pinnedRow(feature, index: index, total: pinned.count)
                }

                section(
                    title: String(localized: "mac_settings_sidebar_available"),
                    systemImage: "square.grid.2x2",
                    items: available,
                    emptyMessage: String(localized: "mac_settings_sidebar_empty_available")
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
            .help(String(localized: "mac_settings_sidebar_move_up"))

            Button {
                moveDown(at: index)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == total - 1)
            .help(String(localized: "mac_settings_sidebar_move_down"))

            Button {
                unpin(feature)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "mac_settings_sidebar_remove"))
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
            .help(String(localized: "mac_settings_sidebar_pin"))
        }
    }

    private func pin(_ feature: AppFeature) {
        guard !appState.macConfiguredTabs.contains(feature) else { return }
        appState.macConfiguredTabs.append(feature)
    }

    private func unpin(_ feature: AppFeature) {
        appState.macConfiguredTabs.removeAll { $0 == feature }
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
    /// Mac-hidden pins (e.g. a Library item previously pinned on
    /// iPhone) ride along unchanged at the tail so a Mac reorder
    /// doesn't disturb non-Mac entries.
    private func rearrange(_ mutate: (inout [AppFeature]) -> Void) {
        var visible = appState.macConfiguredTabs.filter { $0.isAvailableOnMac }
        let hidden = appState.macConfiguredTabs.filter { !$0.isAvailableOnMac }
        mutate(&visible)
        appState.macConfiguredTabs = visible + hidden
    }
}

// MARK: - Account

private struct MacAccountSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showSignIn = false

    var body: some View {
        Form {
            Section(String(localized: "mac_settings_section_ntust")) {
                if appState.authService.hasStoredCredentials {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "mac_settings_signed_in_ntust"))
                    }
                    Button(role: .destructive) {
                        appState.logoutNTUST()
                    } label: {
                        Label(String(localized: "action_sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Text(String(localized: "common_not_signed_in"))
                        .foregroundStyle(.secondary)
                    // Closes the loop for users who took the "Skip for
                    // now" path on `MacLoginView`: without this they'd
                    // have no way back to the login form short of
                    // resetting onboarding state.
                    Button {
                        showSignIn = true
                    } label: {
                        Label(String(localized: "action_sign_in"), systemImage: "person.badge.key.fill")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSignIn) {
            // `showsSkipButton: false` — the user is already inside the
            // app, so "Skip for now" would only re-flip an already-true
            // `didSkipMacLogin` and leave the sheet visually stuck.
            MacLoginView(showsSkipButton: false)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 560)
                // `MacLoginView` already calls `completeOnboarding()` on
                // success; here we just observe the resulting credential
                // flip and dismiss the sheet so the user lands back on
                // the Account tab with the signed-in state showing.
                .onChange(of: appState.authService.hasStoredCredentials) { _, signedIn in
                    if signedIn { showSignIn = false }
                }
        }
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

            // MARK: API endpoint

            Section {
                Text(endpointVM.effectiveURL)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("Effective endpoint")
            } footer: {
                Text("Resolved by PushServerConfig — Keychain override → UserDefaults override → Secrets.plist → localhost fallback.")
            }

            // Surface a previously-saved override that no longer passes
            // the allowlist (e.g. allowlist tightened in a later build).
            // Mirrors the iOS DebugEndpointView — without this section,
            // the Mac user only sees the effective URL silently fall
            // through to the next priority with no breadcrumb explaining
            // why their saved override stopped taking effect.
            if let stale = endpointVM.staleOverride {
                Section {
                    Text(stale)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Stored override no longer accepted")
                } footer: {
                    Text("The allowlist tightened since this value was saved, so it's being ignored and the resolver is using the next priority. Save a new value or clear the override.")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                // Show the example URL above the field instead of as the
                // TextField's leading label — on macOS Form's grouped
                // style the title-string initializer renders a left-side
                // label that eats horizontal space and pushes the input
                // into a sliver. Putting the hint on its own row keeps
                // the input field full-width and easier to paste into.
                Text(verbatim: "http://192.168.X.X:40000/v2")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("", text: $endpointVM.draft, prompt: Text(verbatim: "http://192.168.X.X:40000/v2"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .labelsHidden()

                if let error = endpointVM.validationError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Save") { endpointVM.save() }
                        .disabled(endpointVM.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("Clear override", role: .destructive) { endpointVM.clear() }
                        .disabled(endpointVM.storedOverride == nil)
                }
            } header: {
                Text("Override (Keychain — survives reinstall)")
            } footer: {
                Text("Allowed: api.tigerduck.app (apex + any subdomain) over HTTPS, loopback, or any RFC1918 IPv4. Pointing a Debug build at the prod apex breaks push (apns_env mismatch — sandbox tokens get rejected at registration), but read-side API surfaces still work for testing.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.observeEffectiveNow() }
    }

    @State private var endpointVM = DebugEndpointViewModel()
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
            Text(String(localized: "app_name"))
                .font(.title.bold())
            Text(String(format: String(localized: "mac_about_version_value"), appVersion))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(String(localized: "mac_about_subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .padding(.top, 8)
            Spacer()
            Text(String(localized: "mac_about_copyright"))
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
