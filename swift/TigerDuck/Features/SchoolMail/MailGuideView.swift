#if os(iOS)
import SwiftUI

/// "用其他 App 收信" (design doc §5). Placeholder: the Apple Mail steps are written later;
/// only the @Mail2000 App Store link is real.
struct MailGuideView: View {
    var body: some View {
        List {
            Section(String(localized: "school_mail_guide_apple_mail_title")) {
                Text(String(localized: "school_mail_guide_placeholder"))
                    .foregroundStyle(.secondary)
            }
            Section(String(localized: "school_mail_guide_mail2000_title")) {
                Link(destination: MailConstants.mail2000AppStoreURL) {
                    Label(String(localized: "school_mail_guide_mail2000_link"), systemImage: "arrow.up.forward.app")
                }
            }
        }
        .navigationTitle(String(localized: "school_mail_use_other_app"))
    }
}
#endif
