#if os(macOS)
import SwiftUI

/// Root scene content for the macOS app.
///
/// Routes between the login wall (`MacLoginView`) and the main sidebar
/// layout (`MacContentView`) based on `authService.hasStoredCredentials`.
/// Once credentials are in the Keychain the user sees the sidebar; full
/// logout drops them back to login. Silent re-auth failures keep the
/// sidebar visible and surface through `appState.ntustReauthErrorMessage`
/// instead, mirroring the iOS cached-first contract.
struct MacRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.authService.hasStoredCredentials {
                MacContentView()
            } else {
                MacLoginView()
            }
        }
        .tint(appState.accentColor)
    }
}

/// Main sidebar layout: a list of implemented features on the left, the
/// active feature's detail view on the right.
///
/// `AppFeature.isImplemented` is the source of truth for what surfaces
/// in the sidebar — adding a new Mac-ported feature is purely a matter
/// of flipping that boolean and adding a switch branch in
/// `MacFeatureDetail` below. Until the per-feature port lands each
/// branch renders a `MacFeaturePlaceholder`.
struct MacContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: AppFeature = .home

    private static let sidebarFeatures: [AppFeature] = AppFeature.allCases
        .filter { $0.isImplemented }

    var body: some View {
        NavigationSplitView {
            List(Self.sidebarFeatures, selection: $selection) { feature in
                NavigationLink(value: feature) {
                    Label(feature.displayName, systemImage: feature.iconName)
                }
            }
            .navigationTitle("TigerDuck")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
        } detail: {
            MacFeatureDetail(feature: selection)
                .navigationTitle(selection.displayName)
                .frame(minWidth: 520, minHeight: 360)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            appState.backgroundSync()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Refresh data (⌘R)")
                    }
                }
        }
    }
}

/// Switchboard between the per-feature placeholder views. Each branch
/// will be replaced with a real Mac-native view as features get ported.
private struct MacFeatureDetail: View {
    let feature: AppFeature

    var body: some View {
        switch feature {
        case .home:
            MacHomeView()
        case .classTable:
            MacFeaturePlaceholder(
                feature: feature,
                summary: "Your weekly course schedule will appear here once the Class Table view ports to macOS."
            )
        case .calendar:
            MacFeaturePlaceholder(
                feature: feature,
                summary: "School + Moodle events will surface here once the Calendar view ports to macOS."
            )
        case .announcements:
            MacFeaturePlaceholder(
                feature: feature,
                summary: "NTUST bulletins will surface here once the Bulletins view ports to macOS."
            )
        case .library:
            MacFeaturePlaceholder(
                feature: feature,
                summary: "Library borrow status + renewals will surface here once the Library view ports to macOS."
            )
        case .gpa:
            MacFeaturePlaceholder(
                feature: feature,
                summary: "Semester scores + GPA chart will surface here once the Score view ports to macOS."
            )
        default:
            MacFeaturePlaceholder(
                feature: feature,
                summary: "This feature isn't ported to macOS yet."
            )
        }
    }
}

/// Single empty-state body used by every sidebar destination until the
/// real feature view ports. Renders the feature icon + name from
/// `AppFeature` so the placeholder still respects whatever the iOS
/// localisation file declares.
private struct MacFeaturePlaceholder: View {
    let feature: AppFeature
    let summary: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: feature.iconName)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(feature.displayName)
                .font(.largeTitle.bold())
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text("Cross-platform service layer is already compiled — only the view is pending.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
