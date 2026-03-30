import os
import re

from ntust_courses import search_courses

from course_list import NtustCourseSelectionClient

if __name__ == "__main__":
    student_id = os.getenv("STUDENT_ID")
    password = os.getenv("PASSWORD")

    if not student_id or not password:
        raise RuntimeError("Missing STUDENT_ID or PASSWORD environment variables")

    with NtustCourseSelectionClient(student_id, password) as client:
        ok = client.login()
        if ok:
            html = client.get_class_table()
            result = re.findall(r"<tr>\s*<td>\s*(3?[A-Z][A-Z][A-Z0-9]{6,7})\s*</td>", html)
            print(result)
            # ['CS1007701', 'CS2001301', 'CS2006301', 'CS2008301', 'CS3001302', 'CS3019701', 'EC1013701', 'EC1014701', 'PE139B022']

            for i in result:
                print(search_courses(semester="1142", course_no=i))
                # [{'Semester': '1142', 'CourseNo': 'CS1007701', 'CourseName': '網際網路與應用', 'CourseTeacher': '吳添勝', 'Dimension': '', 'CreditPoint': '3', 'RequireOption': 'E', 'AllYear': 'H', 'ChooseStudent': 26, 'Restrict1': '29', 'Restrict2': '29', 'ThreeStudent': 0, 'AllStudent': 26, 'NTURestrict': '0', 'NTNURestrict': '0', 'CourseTimes': '3', 'PracticalTimes': '0', 'ClassRoomNo': 'RB-504', 'ThreeNode': None, 'Node': 'M10,M8,M9', 'Contents': '限29人', 'NTU_People': 0, 'NTNU_People': 0, 'AbroadPeople': 5}]
                # [{'Semester': '1142', 'CourseNo': 'CS2001301', 'CourseName': '工程數學', 'CourseTeacher': 'Binayak Kar', 'Dimension': '', 'CreditPoint': '3', 'RequireOption': 'R', 'AllYear': 'H', 'ChooseStudent': 79, 'Restrict1': '9999', 'Restrict2': '55', 'ThreeStudent': 0, 'AllStudent': 79, 'NTURestrict': '0', 'NTNURestrict': '0', 'CourseTimes': '3', 'PracticalTimes': '0', 'ClassRoomNo': 'TR-312', 'ThreeNode': None, 'Node': 'M6,M7,R10', 'Contents': 'EMI課程／英語授課', 'NTU_People': 0, 'NTNU_People': 0, 'AbroadPeople': 9}]
                # ...
