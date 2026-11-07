import Defaults
import SwiftUI

struct BrowserPageSettingsView: View {
    @Default(.browserAddressBar) private var addressBar

    var body: some View {
        List {
            Section(SettingsRow.addressBar.label) {
                BrowserAddressBarPicker(selection: $addressBar)
            }
            StorageKindSection(kinds: [.browserDownloads, .websiteData])
        }
    }
}
