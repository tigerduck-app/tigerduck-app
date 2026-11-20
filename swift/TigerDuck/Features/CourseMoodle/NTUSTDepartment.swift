import Foundation

/// The department a bachelor's student ID names, the one the student was admitted to. The ID is a
/// letter, the entry year in three digits, the department's code in two and a serial in three.
/// Each case is the department's course code, which names its strings, and only the codes the
/// school's course rosters confirm are here (`app-translation/CONVENTIONS.md`).
nonisolated enum NTUSTDepartment: String {
    case im = "01", et = "02", me = "03", tx = "04", ct = "05", ch = "06"
    case ee = "07", ba = "08", dt = "10", ad = "13", cs = "15", hc = "30"

    init?(studentId: String?) {
        guard let match = studentId?.wholeMatch(of: /[Bb][0-9]{3}([0-9]{2})[0-9]{3}/) else { return nil }
        self.init(rawValue: String(match.1))
    }

    var name: String {
        switch self {
        case .im: String(localized: "course_member_department_im")
        case .et: String(localized: "course_member_department_et")
        case .me: String(localized: "course_member_department_me")
        case .tx: String(localized: "course_member_department_tx")
        case .ct: String(localized: "course_member_department_ct")
        case .ch: String(localized: "course_member_department_ch")
        case .ee: String(localized: "course_member_department_ee")
        case .ba: String(localized: "course_member_department_ba")
        case .dt: String(localized: "course_member_department_dt")
        case .ad: String(localized: "course_member_department_ad")
        case .cs: String(localized: "course_member_department_cs")
        case .hc: String(localized: "course_member_department_hc")
        }
    }

    var shortName: String {
        switch self {
        case .im: String(localized: "course_member_department_im_short")
        case .et: String(localized: "course_member_department_et_short")
        case .me: String(localized: "course_member_department_me_short")
        case .tx: String(localized: "course_member_department_tx_short")
        case .ct: String(localized: "course_member_department_ct_short")
        case .ch: String(localized: "course_member_department_ch_short")
        case .ee: String(localized: "course_member_department_ee_short")
        case .ba: String(localized: "course_member_department_ba_short")
        case .dt: String(localized: "course_member_department_dt_short")
        case .ad: String(localized: "course_member_department_ad_short")
        case .cs: String(localized: "course_member_department_cs_short")
        case .hc: String(localized: "course_member_department_hc_short")
        }
    }
}
