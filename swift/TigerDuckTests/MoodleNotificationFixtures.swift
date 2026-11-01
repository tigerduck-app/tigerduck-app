import Foundation
@testable import TigerDuck

/// Names and keys as NTUST's Moodle 4.5 gives them; the switch states are made up.
nonisolated enum MoodleNotificationFixtures {
    static let answer = #"""
    {"preferences": {"userid": 3, "disableall": 0,
      "processors": [
        {"displayname": "Web", "name": "popup", "hassettings": false, "contextid": 9, "userconfigured": 1},
        {"displayname": "Email", "name": "email", "hassettings": true, "contextid": 9, "userconfigured": 1},
        {"displayname": "Mobile", "name": "airnotifier", "hassettings": false, "contextid": 9, "userconfigured": 1}
      ],
      "components": [
        {"displayname": "Assignment", "notifications": [
          {"displayname": "Assignment notifications", "preferencekey": "message_provider_mod_assign_assign_notification",
           "processors": [
             {"displayname": "Web", "name": "popup", "locked": false, "userconfigured": 1, "enabled": true},
             {"displayname": "Email", "name": "email", "locked": false, "userconfigured": 1, "enabled": false},
             {"displayname": "Mobile", "name": "airnotifier", "locked": false, "userconfigured": 1, "enabled": true}
           ]},
          {"displayname": "Assignment due soon notification", "preferencekey": "message_provider_mod_assign_assign_due_soon",
           "processors": [
             {"displayname": "Web", "name": "popup", "locked": false, "userconfigured": 1, "enabled": true},
             {"displayname": "Email", "name": "email", "locked": false, "userconfigured": 1, "enabled": true},
             {"displayname": "Mobile", "name": "airnotifier", "locked": false, "userconfigured": 1, "enabled": false}
           ]}
        ]},
        {"displayname": "Lesson", "notifications": []},
        {"displayname": "System", "notifications": [
          {"displayname": "Custom report builder schedules", "preferencekey": "message_provider_moodle_reportbuilderschedule",
           "processors": [
             {"displayname": "Web", "name": "popup", "locked": false, "userconfigured": 1, "enabled": false},
             {"displayname": "Email", "name": "email", "locked": true, "lockedmessage": "Locked on", "userconfigured": 1,
              "enabled": true},
             {"displayname": "Mobile", "name": "airnotifier", "locked": false, "userconfigured": 1, "enabled": false}
           ]}
        ]}
      ]},
     "warnings": []}
    """#

    static let processors = ["popup", "email", "airnotifier"]

    static func preference(_ key: String, enabled: Set<String>, locked: Set<String> = []) -> MoodleNotificationMatrix.Preference {
        MoodleNotificationMatrix.Preference(
            key: "message_provider_\(key)", name: key, processors: processors, enabled: enabled, locked: locked
        )
    }

    static func matrix(_ preferences: [MoodleNotificationMatrix.Preference], disablesAll: Bool = false) -> MoodleNotificationMatrix {
        MoodleNotificationMatrix(
            methods: [.init(id: "popup", name: "Web"), .init(id: "email", name: "Email")],
            components: [.init(name: "Assignment", preferences: preferences)],
            disablesAll: disablesAll
        )
    }

    /// Every component and notification the site lists, in English or in Chinese.
    static func site(chinese: Bool) -> MoodleNotificationMatrix {
        MoodleNotificationMatrix(
            methods: [
                .init(id: "popup", name: chinese ? "網頁彈出式通知" : "Web"),
                .init(id: "email", name: "Email"),
            ],
            components: components.enumerated().map { index, component in
                MoodleNotificationMatrix.Component(
                    name: chinese ? component.zh : component.en,
                    preferences: component.rows.enumerated().map { row, item in
                        let key = "message_provider_\(item.key)"
                        return MoodleNotificationMatrix.Preference(
                            key: key, name: chinese ? item.zh : item.en, processors: processors,
                            enabled: (index + row).isMultiple(of: 2) ? ["popup", "email"] : ["popup"],
                            locked: key == lockedKey ? ["email"] : []
                        )
                    }
                )
            },
            disablesAll: false
        )
    }

    static let lockedKey = "message_provider_moodle_reportbuilderschedule"
    static let longestName = (en: "Turnitin Assignment Instructor Digital Receipt notifications", zh: "用來確認說一個班內簡訊是否由你發出的簡訊")

    private struct Row {
        let key: String
        let en: String
        let zh: String
    }

    private static let components: [(en: String, zh: String, rows: [Row])] = [
        ("Assignment", "作業", [
            Row(key: "mod_assign_assign_notification", en: "Assignment notifications", zh: "作業的通知"),
            Row(key: "mod_assign_assign_due_soon", en: "Assignment due soon notification", zh: "即將到期的作業通知"),
            Row(key: "mod_assign_assign_overdue", en: "Assignment overdue notification", zh: "作業逾期通知"),
            Row(key: "mod_assign_assign_due_digest", en: "Assignments due in 7 days notification", zh: "7 天內到期的作業通知"),
        ]),
        ("Feedback", "回饋單", [
            Row(key: "mod_feedback_submission", en: "Feedback notifications", zh: "回饋單通知"),
            Row(key: "mod_feedback_message", en: "Feedback reminder", zh: "回饋提醒者"),
        ]),
        ("Forum", "討論區", [
            Row(key: "mod_forum_posts", en: "Subscribed forum posts", zh: "訂閱的討論區貼文"),
            Row(key: "mod_forum_digests", en: "Subscribed forum digests", zh: "訂閱的討論區摘要"),
        ]),
        ("Lesson", "編序學習", [
            Row(key: "mod_lesson_graded_essay", en: "Lesson essay graded notification", zh: "學習單元的問答題已經計分的通知"),
        ]),
        ("Quiz", "測驗卷", [
            Row(key: "mod_quiz_quiz_open_soon", en: "Quiz opens soon", zh: "測驗即將開始"),
        ]),
        ("Turnitin Assignment 2", "Turnitin 作業2", [
            Row(key: "mod_turnitintooltwo_submission", en: "Turnitin Assignment Digital Receipt notifications",
                zh: "Turnitin作業電子回條的通知"),
            Row(key: "mod_turnitintooltwo_nonsubmitters", en: "Turnitin Assignment Non Submitter notifications",
                zh: "Turnitin作業非提交者通知"),
            Row(key: "mod_turnitintooltwo_notify_instructor_of_submission",
                en: "Turnitin Assignment Instructor Digital Receipt notifications", zh: "Turnitin作業教師電子回條的通知"),
        ]),
        ("System", "系統", [
            Row(key: "moodle_badgerecipientnotice", en: "Badge recipient notifications", zh: "獎章受獎者的通知"),
            Row(key: "moodle_badgecreatornotice", en: "Badge creator notifications", zh: "獎章創造者的通知"),
            Row(key: "moodle_competencyplancomment", en: "Comment posted on a learning plan", zh: "對一學習計畫的評論"),
            Row(key: "moodle_competencyusercompcomment", en: "Comment posted on a competency", zh: "對一核心能力的評論"),
            Row(key: "moodle_insights", en: "Insights generated by prediction models", zh: "由預測模組產生的洞察"),
            Row(key: "moodle_messagecontactrequests", en: "Message contact requests notification", zh: "訊息聯繫請求通知"),
            Row(key: "moodle_asyncbackupnotification", en: "Asynchronous backup/restore notifications", zh: "非同步備份/還原通知"),
            Row(key: "moodle_gradenotifications", en: "Grade notifications", zh: "成績通知"),
            Row(key: "moodle_newlogin", en: "New login notifications", zh: "新的登入通知"),
            Row(key: "moodle_coursecompleted", en: "Course completed", zh: "已完成課程"),
            Row(key: "moodle_coursecontentupdated", en: "Course content changes", zh: "課程內容變更紀錄"),
            Row(key: "moodle_reportbuilderschedule", en: "Custom report builder schedules", zh: "自訂報表產生器已排程啟動"),
            Row(key: "moodle_enrolcoursewelcomemessage", en: "Welcome message for new course enrolments", zh: "新課程選課歡迎訊息"),
        ]),
        ("Flat file (CSV)", "一般檔案(CSV)", [
            Row(key: "enrol_flatfile_flatfile_enrolment", en: "Flat file enrolment messages", zh: "一般檔案對應選課資訊"),
        ]),
        ("Manual enrolments", "手動選課", [
            Row(key: "enrol_manual_expiry_notification", en: "Manual enrolment expiry notifications", zh: "手動註冊截止通知。"),
        ]),
        ("Self enrolment", "自行選課", [
            Row(key: "enrol_self_expiry_notification", en: "Self enrolment expiry notifications", zh: "自行選課過期通知"),
        ]),
        ("Data privacy", "資料隱私", [
            Row(key: "tool_dataprivacy_datarequestprocessingresults", en: "Data request processing results",
                zh: "Data request processing results"),
        ]),
        ("Inbound message configuration", "班內簡訊配置", [
            Row(key: "tool_messageinbound_invalidrecipienthandler",
                en: "Message to confirm that an inbound message came from you", zh: "用來確認說一個班內簡訊是否由你發出的簡訊"),
            Row(key: "tool_messageinbound_messageprocessingerror",
                en: "Warning when an inbound message could not be processed", zh: "當班內簡訊無法被處理時提出警告"),
            Row(key: "tool_messageinbound_messageprocessingsuccess",
                en: "Confirmation that a message was successfully processed", zh: "確認一則簡訊已經順利處理完"),
        ]),
    ]
}
