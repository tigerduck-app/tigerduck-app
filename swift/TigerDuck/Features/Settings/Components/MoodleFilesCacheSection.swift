import SwiftUI

struct MoodleFilesCacheSection: View {
    var downloads: MoodleFileDownloads = .shared

    @State private var bytes: Int?

    var body: some View {
        Section {
            LabeledContent(String(localized: "school_mail_cache_size")) {
                Text(bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                    .monospacedDigit()
            }
            .task { bytes = await downloads.measure() }
            Button(String(localized: "school_mail_clear_cache")) {
                Task { bytes = await downloads.clear() }
            }
            .disabled((bytes ?? 0) == 0)
        } header: {
            Text(String(localized: "settings_moodle_files_section"))
        }
    }
}
