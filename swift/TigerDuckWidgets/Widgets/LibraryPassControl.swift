#if os(iOS)
import SwiftUI
import WidgetKit

/// One control serves Control Center, the Lock Screen and the Action button. iOS prefixes the
/// action hint with "Hold to" on the Action button (Apple's "Adding refinements and configuration
/// to controls").
struct LibraryPassControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "LibraryPassControl") {
            ControlWidgetButton(action: OpenLibraryPassIntent()) {
                Label(String(localized: "library_virtual_pass_title"), systemImage: "qrcode")
                    .controlWidgetActionHint(String(localized: "library_virtual_pass_action_hint"))
            }
        }
        .displayName(OpenLibraryPassIntent.title)
    }
}
#endif
