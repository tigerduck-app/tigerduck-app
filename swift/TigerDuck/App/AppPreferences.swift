import Defaults
import SwiftUI

@MainActor
@Observable
final class AppPreferences {
    @ObservationIgnored private var hooks = Hooks()
    private var toggles = AppDisplayToggles()

    var willChangeLanguage: () -> Void {
        get { hooks.languageWillChange }
        set { hooks.languageWillChange = newValue }
    }
    var onCourseLabelsChange: () -> Void {
        get { hooks.courseLabelsChange }
        set { hooks.courseLabelsChange = newValue }
    }

    private struct Hooks {
        var languageWillChange: () -> Void = {}
        var courseLabelsChange: () -> Void = {}
    }

    @ObservationIgnored private let debouncedWidgetReload = WidgetReloadCoordinator()

    var accentColorHex: Int {
        get { toggles.accentColorHex }
        set { toggles.accentColorHex = newValue }
    }
    var moodleOpenTarget: MoodleOpenTarget {
        get { toggles.moodleOpenTarget }
        set { toggles.moodleOpenTarget = newValue }
    }
    var invertSliderDirection: Bool {
        get { toggles.invertSliderDirection }
        set { toggles.invertSliderDirection = newValue }
    }
    var showAbsoluteAssignmentTime: Bool {
        get { toggles.showAbsoluteAssignmentTime }
        set { toggles.showAbsoluteAssignmentTime = newValue }
    }
    var alwaysShowAllPeriods: Bool {
        get { toggles.alwaysShowAllPeriods }
        set { toggles.alwaysShowAllPeriods = newValue }
    }
    var showClassroomInClassTable: Bool {
        get { toggles.showClassroomInClassTable }
        set { toggles.showClassroomInClassTable = newValue }
    }
    var flipToLibraryEnabled: Bool {
        get { toggles.flipToLibraryEnabled }
        set { toggles.flipToLibraryEnabled = newValue }
    }
    var visualPreset: VisualPreset {
        get { toggles.visualPreset }
        set { toggles.visualPreset = newValue }
    }

    static let themeColors: [(nameKey: LocalizedStringResource, hex: Int)] = [
        ("color_name_blue", 0x007AFF),
        ("color_name_purple", 0xAF52DE),
        ("color_name_pink", 0xFF2D55),
        ("color_name_red", 0xFF3B30),
        ("color_name_orange", 0xFF9500),
        ("color_name_green", 0x34C759),
        ("color_name_cyan", 0x5AC8FA),
    ]

    var courseCardFontScale: Double = CourseCardFontScaleStore().read() {
        didSet {
            let newSnapped = CourseCardFontScale.normalize(courseCardFontScale)
            let oldSnapped = CourseCardFontScale.normalize(oldValue)
            guard newSnapped != oldSnapped else { return }
            CourseCardFontScaleStore().write(newSnapped)
            let coordinator = debouncedWidgetReload
            Task { @MainActor in
                coordinator.requestReload()
            }
        }
    }

    var appLanguage: String = Defaults[.appLanguage] {
        didSet {
            guard appLanguage != oldValue else { return }
            willChangeLanguage()
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

    static func accentColor(hex: Int) -> Color {
        let rgb = Int(UInt(bitPattern: hex) & 0xFFFFFF)
        return .adaptive(light: Color(hex: UInt(AccentContrast.readableOnLight(rgb))), dark: Color(hex: UInt(rgb)))
    }

    var visualStylePolicy: VisualStylePolicy {
        VisualStylePolicy(preset: visualPreset)
    }
}
