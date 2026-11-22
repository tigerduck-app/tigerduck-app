import SwiftUI
import TigerDuckCore

extension EnvironmentValues {
    @Entry var appLanguage = AppLanguage(tag: nil)
}

extension View {
    func appLanguage(_ language: AppLanguage) -> some View {
        environment(\.appLanguage, language).transformEnvironment(\.locale) { locale in
            if let tag = language.tag { locale = Locale(identifier: tag) }
        }
    }
}
