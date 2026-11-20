import Foundation

/// The department, graduate institute or program a student ID names, the one the student was
/// admitted to. A bachelor's ID starts with B, a master's with M and a doctoral student's with D,
/// then the entry year in three digits, the department's code in two and a serial in three. Each
/// case is the department's course code, which names its strings, under the name the school's
/// course department code table gives it (`app-translation/CONVENTIONS.md`).
nonisolated enum NTUSTDepartment: String {
    case im = "01", et = "02", me = "03", tx = "04", ct = "05", ch = "06", ee = "07", ba = "08"
    case mi = "09", dt = "10", ve = "11", ac = "12", ad = "13", cs = "15", mg = "16", fl = "17"
    case fn = "18", eo = "19", tm = "20", ma = "21", en = "22", be = "23", pa = "24", ci = "25"
    case ic = "27", hc = "30", ce = "31", ec = "32", mb = "33", gd = "37"
    case si = "51", ai = "52", es = "53", `as` = "54"
    // No 34 or 35: a 2019 list of the codes gives 34 to the English-taught program for foreign
    // students, yet the students in its TE courses have 35 in their IDs
    // (https://www.ptt.cc/bbs/NTUST_Talk/M.1569231954.A.B44.html).

    init?(studentId: String?) {
        guard let match = studentId?.wholeMatch(of: /[BbMmDd][0-9]{3}([0-9]{2})[0-9]{3}/) else { return nil }
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
        case .mi: String(localized: "course_member_department_mi")
        case .dt: String(localized: "course_member_department_dt")
        case .ve: String(localized: "course_member_department_ve")
        case .ac: String(localized: "course_member_department_ac")
        case .ad: String(localized: "course_member_department_ad")
        case .cs: String(localized: "course_member_department_cs")
        case .mg: String(localized: "course_member_department_mg")
        case .fl: String(localized: "course_member_department_fl")
        case .fn: String(localized: "course_member_department_fn")
        case .eo: String(localized: "course_member_department_eo")
        case .tm: String(localized: "course_member_department_tm")
        case .ma: String(localized: "course_member_department_ma")
        case .en: String(localized: "course_member_department_en")
        case .be: String(localized: "course_member_department_be")
        case .pa: String(localized: "course_member_department_pa")
        case .ci: String(localized: "course_member_department_ci")
        case .ic: String(localized: "course_member_department_ic")
        case .hc: String(localized: "course_member_department_hc")
        case .ce: String(localized: "course_member_department_ce")
        case .ec: String(localized: "course_member_department_ec")
        case .mb: String(localized: "course_member_department_mb")
        case .gd: String(localized: "course_member_department_gd")
        case .si: String(localized: "course_member_department_si")
        case .ai: String(localized: "course_member_department_ai")
        case .es: String(localized: "course_member_department_es")
        case .`as`: String(localized: "course_member_department_as")
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
        case .mi: String(localized: "course_member_department_mi_short")
        case .dt: String(localized: "course_member_department_dt_short")
        case .ve: String(localized: "course_member_department_ve_short")
        case .ac: String(localized: "course_member_department_ac_short")
        case .ad: String(localized: "course_member_department_ad_short")
        case .cs: String(localized: "course_member_department_cs_short")
        case .mg: String(localized: "course_member_department_mg_short")
        case .fl: String(localized: "course_member_department_fl_short")
        case .fn: String(localized: "course_member_department_fn_short")
        case .eo: String(localized: "course_member_department_eo_short")
        case .tm: String(localized: "course_member_department_tm_short")
        case .ma: String(localized: "course_member_department_ma_short")
        case .en: String(localized: "course_member_department_en_short")
        case .be: String(localized: "course_member_department_be_short")
        case .pa: String(localized: "course_member_department_pa_short")
        case .ci: String(localized: "course_member_department_ci_short")
        case .ic: String(localized: "course_member_department_ic_short")
        case .hc: String(localized: "course_member_department_hc_short")
        case .ce: String(localized: "course_member_department_ce_short")
        case .ec: String(localized: "course_member_department_ec_short")
        case .mb: String(localized: "course_member_department_mb_short")
        case .gd: String(localized: "course_member_department_gd_short")
        case .si: String(localized: "course_member_department_si_short")
        case .ai: String(localized: "course_member_department_ai_short")
        case .es: String(localized: "course_member_department_es_short")
        case .`as`: String(localized: "course_member_department_as_short")
        }
    }
}
