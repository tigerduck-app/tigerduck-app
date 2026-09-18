#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// Every School Mail key resolves in English and Traditional Chinese — a missing key
/// would ship its raw name on screen.
struct SchoolMailStringsTests {
    static let keys = [
        "feature_school_mail", "feature_school_mail_short", "school_mail_account_title",
        "school_mail_sign_in_prompt_title", "school_mail_sign_in_note", "school_mail_forgot_password",
        "school_mail_error_auth", "school_mail_error_network", "school_mail_error_certificate",
        "school_mail_error_busy", "school_mail_error_generic", "school_mail_auth_failed_banner",
        "school_mail_auth_failed_notification_title", "school_mail_auth_failed_notification_text",
        "school_mail_new_mail_count", "school_mail_notification_title", "school_mail_no_sender", "school_mail_no_subject",
        "school_mail_folder_inbox", "school_mail_folder_sent", "school_mail_folder_drafts",
        "school_mail_folder_junk", "school_mail_folder_trash", "school_mail_folder_more",
        "school_mail_search_prompt", "school_mail_search_local_only", "school_mail_unread_only",
        "school_mail_compose", "school_mail_use_other_app", "school_mail_empty_title",
        "school_mail_empty_message", "school_mail_load_failed_title", "school_mail_external_badge",
        "school_mail_to", "school_mail_cc", "school_mail_bcc", "school_mail_subject", "school_mail_body",
        "school_mail_show_cc_bcc", "school_mail_send", "school_mail_send_failed",
        "school_mail_invalid_recipients", "school_mail_no_recipient", "school_mail_too_large",
        "school_mail_add_attachment", "school_mail_leave_title", "school_mail_save_draft",
        "school_mail_discard", "school_mail_keep_editing", "school_mail_reply", "school_mail_reply_all",
        "school_mail_forward", "school_mail_mark_unread", "school_mail_mark_read", "school_mail_move_to",
        "school_mail_delete", "school_mail_delete_forever_title", "school_mail_delete_forever_message",
        "school_mail_view_mode", "school_mail_view_formatted", "school_mail_view_plain",
        "school_mail_view_source", "school_mail_source_large_title", "school_mail_source_large_message",
        "school_mail_source_failed", "school_mail_copy_all", "school_mail_parse_failed",
        "school_mail_quote_header",
        "school_mail_attachments", "school_mail_open", "school_mail_details_to", "school_mail_details_cc",
        "school_mail_warning_external", "school_mail_warning_display_name", "school_mail_warning_password",
        "school_mail_warning_attachment", "school_mail_remote_images_blocked", "school_mail_load_images",
        "school_mail_link_title", "school_mail_link_host", "school_mail_link_mismatch",
        "school_mail_link_punycode", "school_mail_link_insecure", "school_mail_risky_title",
        "school_mail_risky_message", "school_mail_settings_notifications",
        "school_mail_settings_notifications_hint", "school_mail_settings_display_name",
        "school_mail_settings_display_name_hint", "school_mail_settings_diagnostics",
        "school_mail_notification_settings_title",
        "school_mail_settings_no_checks", "school_mail_guide_placeholder", "school_mail_saved",
        "school_mail_guide_apple_mail_title", "school_mail_guide_mail2000_title",
        "school_mail_guide_mail2000_link", "school_mail_attachment_share",
        "school_mail_settings_background_refresh_hint",
        "school_mail_forwarded_header", "school_mail_forward_from",
        "school_mail_forward_date", "school_mail_forward_subject",
    ]

    @Test(arguments: ["en", "zh-Hant"])
    func everyKeyResolves(locale: String) throws {
        let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let missing = Self.keys.filter { bundle.localizedString(forKey: $0, value: "__missing__", table: nil) == "__missing__" }
        #expect(missing.isEmpty, "missing in \(locale): \(missing)")
    }
}
#endif
