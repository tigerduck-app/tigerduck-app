import Defaults
import SwiftUI

/// The display preferences the views bind to. Each one is read from its Defaults key once and
/// written back on every change.
@MainActor
@Observable
final class AppPreferences {
    /// Runs before a language change is stored, so work fetched in the old language can stop.
    @ObservationIgnored var onLanguageChange: () -> Void = {}
    /// Runs after a change to how course and classroom names are shown.
    @ObservationIgnored var onCourseLabelsChange: () -> Void = {}

    /// The slider's stepped binding sets the font scale on every step of a drag, up to 16 across
    /// its range; the coordinator folds those into one debounced WidgetKit reload.
    @ObservationIgnored private let widgetReloadCoordinator = WidgetReloadCoordinator()

    var accentColorHex: Int = Defaults[.accentColorHex] {
        didSet {
            Defaults[.accentColorHex] = accentColorHex
        }
    }

    static let themeColors: [(nameKey: String, hex: Int)] = [
        ("color_name_blue", 0x007AFF),
        ("color_name_purple", 0xAF52DE),
        ("color_name_pink", 0xFF2D55),
        ("color_name_red", 0xFF3B30),
        ("color_name_orange", 0xFF9500),
        ("color_name_green", 0x34C759),
        ("color_name_cyan", 0x5AC8FA),
    ]

    /// Mac only: where the "open in Moodle" actions route to. The iPad Moodle app installed from
    /// the Mac App Store registers `moodlemobile://` too, so its users can choose the deep link.
    var macMoodleOpenTarget: MoodleOpenTarget = Defaults[.macMoodleOpenTarget] {
        didSet { Defaults[.macMoodleOpenTarget] = macMoodleOpenTarget }
    }

    var invertSliderDirection: Bool = Defaults[.invertSliderDirection] {
        didSet { Defaults[.invertSliderDirection] = invertSliderDirection }
    }

    var showAbsoluteAssignmentTime: Bool = Defaults[.showAbsoluteAssignmentTime] {
        didSet { Defaults[.showAbsoluteAssignmentTime] = showAbsoluteAssignmentTime }
    }

    var alwaysShowAllPeriods: Bool = Defaults[.alwaysShowAllPeriods] {
        didSet { Defaults[.alwaysShowAllPeriods] = alwaysShowAllPeriods }
    }

    var showClassroomInClassTable: Bool = Defaults[.showClassroomInClassTable] {
        didSet { Defaults[.showClassroomInClassTable] = showClassroomInClassTable }
    }

    var flipToLibraryEnabled: Bool = Defaults[.flipToLibraryEnabled] {
        didSet { Defaults[.flipToLibraryEnabled] = flipToLibraryEnabled }
    }

    var courseCardFontScale: Double = CourseCardFontScaleStore().read() {
        didSet {
            let newSnapped = CourseCardFontScale.normalize(courseCardFontScale)
            let oldSnapped = CourseCardFontScale.normalize(oldValue)
            guard newSnapped != oldSnapped else { return }
            CourseCardFontScaleStore().write(newSnapped)
            let coordinator = widgetReloadCoordinator
            Task { @MainActor in
                coordinator.requestReload()
            }
        }
    }

    var visualPreset: VisualPreset = Defaults[.visualPreset] {
        didSet { Defaults[.visualPreset] = visualPreset }
    }

    var appLanguage: String = Defaults[.appLanguage] {
        didSet {
            guard appLanguage != oldValue else { return }
            onLanguageChange()
            Defaults[.appLanguage] = appLanguage
            LanguageManager.apply(appLanguage)
            CourseFetch.handleLanguageChange()
            NotificationCenter.default.post(name: AppConstants.languageDidChange, object: nil)
        }
    }

    var useEnglishCourseAbbreviation: Bool = Defaults[.useEnglishCourseAbbreviation] {
        didSet {
            guard useEnglishCourseAbbreviation != oldValue else { return }
            Defaults[.useEnglishCourseAbbreviation] = useEnglishCourseAbbreviation
            onCourseLabelsChange()
        }
    }

    var useEnglishClassroomAbbreviation: Bool = Defaults[.useEnglishClassroomAbbreviation] {
        didSet {
            guard useEnglishClassroomAbbreviation != oldValue else { return }
            Defaults[.useEnglishClassroomAbbreviation] = useEnglishClassroomAbbreviation
            onCourseLabelsChange()
        }
    }

    var classroomMandarinDisplay: String = Defaults[.classroomMandarinDisplay] {
        didSet {
            guard classroomMandarinDisplay != oldValue else { return }
            let valid: Set<String> = ["original", "pinyin", "translated"]
            if !valid.contains(classroomMandarinDisplay) {
                classroomMandarinDisplay = "original"
                return
            }
            Defaults[.classroomMandarinDisplay] = classroomMandarinDisplay
            onCourseLabelsChange()
        }
    }

    nonisolated static func decodeConfiguredTabs(
        _ data: Data?,
        isShown: (AppFeature) -> Bool = { $0.isImplemented }
    ) -> [AppFeature]? {
        guard let data, let rawValues = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        let features = rawValues.compactMap { AppFeature(rawValue: $0) }.filter(isShown)
        return features.isEmpty ? nil : features
    }

    var configuredTabs: [AppFeature] = {
        AppPreferences.decodeConfiguredTabs(Defaults[.configuredTabsData]) ?? AppFeature.defaultTabs
    }() {
        didSet {
            do {
                let data = try JSONEncoder().encode(configuredTabs.map(\.rawValue))
                Defaults[.configuredTabsData] = data
            } catch {
                AppLogger.captureError(error, context: ["phase": "configuredTabs.encode"])
            }
        }
    }

    #if os(macOS)
    var macConfiguredTabs: [AppFeature] = {
        if let data = Defaults[.macConfiguredTabsData],
           let rawValues = try? JSONDecoder().decode([String].self, from: data) {
            let features = rawValues.compactMap { AppFeature(rawValue: $0) }
            return features.isEmpty ? AppFeature.macDefaultTabs : features
        }
        return AppFeature.macDefaultTabs
    }() {
        didSet {
            do {
                let data = try JSONEncoder().encode(macConfiguredTabs.map(\.rawValue))
                Defaults[.macConfiguredTabsData] = data
            } catch {
                AppLogger.captureError(error, context: ["phase": "macConfiguredTabs.encode"])
            }
        }
    }
    #endif

    var accentColor: Color { Self.accentColor(hex: accentColorHex) }

    /// Orange, green and cyan read faintly on the light cards, so light mode draws an accent
    /// at the tone that reads there; dark mode keeps it as saved.
    static func accentColor(hex: Int) -> Color {
        // bitPattern: a corrupted negative value would trap in the Int to UInt conversion.
        let rgb = Int(UInt(bitPattern: hex) & 0xFFFFFF)
        return .adaptive(light: Color(hex: UInt(AccentContrast.readableOnLight(rgb))), dark: Color(hex: UInt(rgb)))
    }

    var visualStylePolicy: VisualStylePolicy {
        VisualStylePolicy(preset: visualPreset)
    }
}
