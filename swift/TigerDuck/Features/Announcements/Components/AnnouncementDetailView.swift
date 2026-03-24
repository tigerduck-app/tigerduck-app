import SwiftUI
import SafariServices

struct AnnouncementDetailView: View {
    @Environment(AppState.self) private var appState
    let announcement: SDAnnouncement
    @State private var showInAppBrowser = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                    HStack {
                        Text(announcement.department)
                            .font(TigerDuckTheme.Typography.caption)
                            .foregroundStyle(Color.accentPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentPrimary.opacity(0.15), in: Capsule())

                        Spacer()

                        Text(announcement.publishDate.shortDateString)
                            .font(TigerDuckTheme.Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }

                    Text(announcement.title)
                        .font(TigerDuckTheme.Typography.title)
                        .foregroundStyle(Color.textPrimary)

                    Divider().background(Color.textSecondary)

                    // HTML content with image support
                    if let htmlContent = announcement.htmlContent {
                        HTMLContentView(html: htmlContent)
                    } else {
                        Text(announcement.summary)
                            .font(TigerDuckTheme.Typography.body)
                            .foregroundStyle(Color.textPrimary)
                            .lineSpacing(6)
                    }
                }
                .padding(TigerDuckTheme.Spacing.lg)
                .padding(.bottom, 80) // space for floating button
            }

            // Floating button: open original announcement
            if let urlString = announcement.detailUrl, let url = URL(string: urlString) {
                Button {
                    if appState.browserPreference == .inApp {
                        showInAppBrowser = true
                    } else {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("原文公告", systemImage: "safari")
                        .font(.callout.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.accentPrimary, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                }
                .padding(TigerDuckTheme.Spacing.lg)
            }
        }
        .background(Color.backgroundPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showInAppBrowser) {
            if let urlString = announcement.detailUrl, let url = URL(string: urlString) {
                InAppBrowserView(url: url)
                    .ignoresSafeArea()
            }
        }
    }
}

/// Renders HTML content with image support using AttributedString
struct HTMLContentView: View {
    let html: String

    var body: some View {
        if let nsAttr = try? NSAttributedString(
            data: Data(wrappedHTML.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        ), let attr = try? AttributedString(nsAttr) {
            Text(attr)
                .foregroundStyle(Color.textPrimary)
        } else {
            Text(html)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
        }
    }

    /// Wrap raw HTML with base styling for dark mode
    private var wrappedHTML: String {
        """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system; font-size: 16px; color: white; }
        img { max-width: 100%; height: auto; border-radius: 8px; }
        a { color: #007AFF; }
        </style></head><body>\(html)</body></html>
        """
    }
}
