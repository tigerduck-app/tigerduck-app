import SwiftUI

/// The settings' "Moodle materials" section: what the downloaded Moodle files take on the device,
/// measured each time the screen opens, and a button that deletes them all with no confirmation,
/// since each downloads again on a tap. The cached lists stay, so every screen still fills.
struct MoodleFilesCacheSection: View {
    var downloads: MoodleFileDownloads = .shared

    /// Nil until the first measure ends, so the row says "…" rather than a size not measured.
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
