import SwiftUI

struct MoodleFilesCacheSection: View {
    var downloads: MoodleFileDownloads = .shared
    var userData: MoodleUserData = .shared

    @State private var bytes: Int?

    var body: some View {
        Section {
            LabeledContent(String(localized: "school_mail_cache_size")) {
                Text(bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                    .monospacedDigit()
            }
            .task { bytes = await Self.measure(downloads, userData) }
            Button(String(localized: "school_mail_clear_cache")) {
                Task { bytes = await Self.clear(downloads, userData) }
            }
            .disabled((bytes ?? 0) == 0)
        } header: {
            Text(String(localized: "settings_moodle_files_section"))
        }
    }

    static func measure(_ downloads: MoodleFileDownloads, _ userData: MoodleUserData) async -> Int {
        await downloads.measure() + userData.measure()
    }

    static func clear(_ downloads: MoodleFileDownloads, _ userData: MoodleUserData) async -> Int {
        _ = await downloads.clear()
        await userData.clear()
        return await measure(downloads, userData)
    }
}
