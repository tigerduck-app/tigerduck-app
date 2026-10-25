"""Tests for tools/check_privacy_manifests.py: python3 -m unittest discover -s tools -p 'test_*.py'"""
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path

import check_privacy_manifests as cpm

# A project shaped like swift/TigerDuck.xcodeproj: an app on two synchronized folders that links
# a local package, an extension that pulls one file out of the app's folder, and a test bundle.
PROJECT = """// !$*UTF8*$!
{
\tobjects = {
\t\tAAAAAAAAAAAAAAAAAAAAAA01 /* SwiftMail */ = {isa = XCSwiftPackageProductDependency; productName = Mail; };
\t\tAAAAAAAAAAAAAAAAAAAAAA02 /* Exceptions for "App" folder in "App" target */ = {
\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;
\t\t\tmembershipExceptions = (
\t\t\t\tInfo.plist,
\t\t\t);
\t\t\ttarget = AAAAAAAAAAAAAAAAAAAAAA10 /* App */;
\t\t};
\t\tAAAAAAAAAAAAAAAAAAAAAA03 /* Exceptions for "App" folder in "My Ext" target */ = {
\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;
\t\t\tmembershipExceptions = (
\t\t\t\tClock/Clock.swift,
\t\t\t);
\t\t\ttarget = AAAAAAAAAAAAAAAAAAAAAA11 /* My Ext */;
\t\t};
\t\tAAAAAAAAAAAAAAAAAAAAAA04 /* App */ = {
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\texceptions = (
\t\t\t\tAAAAAAAAAAAAAAAAAAAAAA02 /* Exceptions for "App" folder in "App" target */,
\t\t\t\tAAAAAAAAAAAAAAAAAAAAAA03 /* Exceptions for "App" folder in "My Ext" target */,
\t\t\t);
\t\t\tpath = App;
\t\t\tsourceTree = "<group>";
\t\t};
\t\tAAAAAAAAAAAAAAAAAAAAAA05 /* Shared */ = {
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = Shared;
\t\t\tsourceTree = "<group>";
\t\t};
\t\tAAAAAAAAAAAAAAAAAAAAAA06 /* My Ext */ = {
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = "My Ext";
\t\t\tsourceTree = "<group>";
\t\t};
\t\tAAAAAAAAAAAAAAAAAAAAAA07 /* Tests */ = {
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = Tests;
\t\t\tsourceTree = "<group>";
\t\t};
\t\tAAAAAAAAAAAAAAAAAAAAAA08 /* XCLocalSwiftPackageReference "Packages/Mail" */ = {
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = Packages/Mail;
\t\t};
\t\tAAAAAAAAAAAAAAAAAAAAAA09 /* Mail */ = {
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tproductName = Mail;
\t\t};
\t\tAAAAAAAAAAAAAAAAAAAAAA10 /* App */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\tAAAAAAAAAAAAAAAAAAAAAA04 /* App */,
\t\t\t\tAAAAAAAAAAAAAAAAAAAAAA05 /* Shared */,
\t\t\t);
\t\t\tname = App;
\t\t\tpackageProductDependencies = (
\t\t\t\tAAAAAAAAAAAAAAAAAAAAAA09 /* Mail */,
\t\t\t);
\t\t\tproductType = "com.apple.product-type.application";
\t\t};
\t\tAAAAAAAAAAAAAAAAAAAAAA11 /* My Ext */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\tAAAAAAAAAAAAAAAAAAAAAA06 /* My Ext */,
\t\t\t);
\t\t\tname = "My Ext";
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t};
\t\tAAAAAAAAAAAAAAAAAAAAAA12 /* Tests */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\tAAAAAAAAAAAAAAAAAAAAAA07 /* Tests */,
\t\t\t);
\t\t\tname = Tests;
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t};
\t};
}
"""

PACKAGE_SHIPPING_MANIFEST = (
    'products: [.library(name: "Mail", targets: ["Mail"])]\n'
    'targets: [.target(name: "Mail", resources: [.copy("PrivacyInfo.xcprivacy")])]\n'
)

DEFAULTS = "NSPrivacyAccessedAPICategoryUserDefaults"
BOOT_TIME = "NSPrivacyAccessedAPICategorySystemBootTime"
DISK_SPACE = "NSPrivacyAccessedAPICategoryDiskSpace"
TIMESTAMP = "NSPrivacyAccessedAPICategoryFileTimestamp"


def manifest(**reasons: list[str]) -> bytes:
    return plistlib.dumps({"NSPrivacyTracking": False, "NSPrivacyAccessedAPITypes": [
        {"NSPrivacyAccessedAPIType": category, "NSPrivacyAccessedAPITypeReasons": codes}
        for category, codes in reasons.items()]})


class PrivacyManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.write("swift/TigerDuck.xcodeproj/project.pbxproj", PROJECT)
        self.write("swift/App/AppView.swift", "let store = UserDefaults.standard\n")
        self.write("swift/App/Info.plist", "")
        self.write("swift/App/Clock/Clock.swift", "enum Clock {}\n")
        self.write("swift/Shared/Boot.swift", "// systemUptime is not read here\n")
        self.write("swift/My Ext/Widget.swift", "struct Widget {}\n")
        self.write("swift/Tests/AppTests.swift", "let uptime = ProcessInfo.processInfo.systemUptime\n")
        self.write("swift/Packages/Mail/Package.swift", 'products: [.library(name: "Mail", targets: ["Mail"])]\n')
        self.write("swift/Packages/Mail/Sources/Mail/Mail.swift", "struct Mail {}\n")
        self.write("swift/App/PrivacyInfo.xcprivacy", manifest(**{DEFAULTS: ["CA92.1"]}))
        self.write("swift/My Ext/PrivacyInfo.xcprivacy", manifest())

    def write(self, path: str, content: str | bytes) -> None:
        (self.root / path).parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            (self.root / path).write_bytes(content)
        else:
            (self.root / path).write_text(content)

    def test_the_repository_declares_what_it_uses(self) -> None:
        self.assertEqual(cpm.problems(), [])

    def test_the_fixture_passes(self) -> None:
        self.assertEqual(cpm.problems(self.root), [])

    def test_a_target_without_a_manifest_fails(self) -> None:
        (self.root / "swift/My Ext/PrivacyInfo.xcprivacy").unlink()
        self.assertEqual(cpm.problems(self.root), ["My Ext: builds 0 PrivacyInfo.xcprivacy files, needs one: none"])

    def test_a_manifest_a_membership_exception_leaves_out_fails(self) -> None:
        project = PROJECT.replace("\t\t\t\tInfo.plist,\n", "\t\t\t\tInfo.plist,\n\t\t\t\tPrivacyInfo.xcprivacy,\n")
        self.write("swift/TigerDuck.xcodeproj/project.pbxproj", project)
        self.assertEqual(cpm.problems(self.root), ["App: builds 0 PrivacyInfo.xcprivacy files, needs one: none"])

    def test_a_second_manifest_in_another_folder_of_the_target_fails(self) -> None:
        self.write("swift/Shared/PrivacyInfo.xcprivacy", manifest())
        self.assertEqual(cpm.problems(self.root), [
            "App: builds 2 PrivacyInfo.xcprivacy files, needs one: "
            "swift/App/PrivacyInfo.xcprivacy, swift/Shared/PrivacyInfo.xcprivacy"])

    def test_a_file_pulled_in_from_another_folder_counts_for_the_extension(self) -> None:
        self.write("swift/App/Clock/Clock.swift", "let shared = UserDefaults(suiteName: \"group\")\n")
        self.assertEqual(cpm.problems(self.root), [
            f"My Ext: swift/App/Clock/Clock.swift uses `{DEFAULTS}`, "
            "which swift/My Ext/PrivacyInfo.xcprivacy does not declare"])

    def test_an_undeclared_category_fails_and_a_comment_does_not_count(self) -> None:
        self.write("swift/Shared/Boot.swift", "let up = ProcessInfo.processInfo.systemUptime // systemUptime\n")
        self.assertEqual(cpm.problems(self.root), [
            f"App: swift/Shared/Boot.swift uses `{BOOT_TIME}`, which swift/App/PrivacyInfo.xcprivacy does not declare"])

    def test_each_spelling_of_a_timestamp_or_disk_space_api_counts(self) -> None:
        spellings = {
            "let date = values.contentModificationDate": TIMESTAMP,
            "let keys: [URLResourceKey] = [.contentAccessDateKey]": TIMESTAMP,
            "let date = values.contentAccessDate": TIMESTAMP,
            "let key = NSFileCreationDate": TIMESTAMP,
            "let key = NSFileModificationDate": TIMESTAMP,
            "let key = NSURLContentModificationDateKey": TIMESTAMP,
            "let key = NSURLCreationDateKey": TIMESTAMP,
            "let free = values.volumeAvailableCapacityForImportantUsage": DISK_SPACE,
            "let total = values.volumeTotalCapacity": DISK_SPACE,
            "let key = NSFileSystemFreeSize": DISK_SPACE,
            "let key = NSFileSystemSize": DISK_SPACE,
        }
        for line, category in spellings.items():
            with self.subTest(line):
                self.write("swift/Shared/Boot.swift", line + "\n")
                self.assertEqual(cpm.problems(self.root), [
                    f"App: swift/Shared/Boot.swift uses `{category}`, which swift/App/PrivacyInfo.xcprivacy does not declare"])

    def test_a_project_the_parser_finds_no_app_in_fails(self) -> None:
        projects = {
            "no app target": PROJECT.replace('"com.apple.product-type.application"', '"com.apple.product-type.framework"'),
            "no targets": PROJECT.replace("isa = PBXNativeTarget;", "isa = PBXAggregateTarget;"),
        }
        for label, project in projects.items():
            with self.subTest(label):
                self.write("swift/TigerDuck.xcodeproj/project.pbxproj", project)
                self.assertEqual(cpm.problems(self.root), [
                    "found no application target in swift/TigerDuck.xcodeproj/project.pbxproj; "
                    "the parser no longer matches its format"])

    def test_a_reason_apple_does_not_list_for_the_category_fails(self) -> None:
        self.write("swift/App/PrivacyInfo.xcprivacy", manifest(**{DEFAULTS: ["C617.1"]}))
        self.assertEqual(cpm.problems(self.root), [
            f"App: `{DEFAULTS}` needs one or more of ['1C8F.1', 'AC6B.1', 'C56D.1', 'CA92.1'], not ['C617.1']"])

    def test_a_linked_local_package_counts_unless_it_ships_its_own_manifest(self) -> None:
        self.write("swift/Packages/Mail/Sources/Mail/Mail.swift", "let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey]\n")
        self.assertEqual(cpm.problems(self.root), [
            f"App: swift/Packages/Mail/Sources/Mail/Mail.swift uses `{DISK_SPACE}`, "
            "which swift/App/PrivacyInfo.xcprivacy does not declare"])
        self.write("swift/Packages/Mail/Package.swift", PACKAGE_SHIPPING_MANIFEST)
        self.write("swift/Packages/Mail/Sources/Mail/PrivacyInfo.xcprivacy", manifest(**{DISK_SPACE: ["E174.1"]}))
        self.assertEqual(cpm.problems(self.root), [])

    def test_a_package_manifest_that_is_not_a_resource_fails(self) -> None:
        self.write("swift/Packages/Mail/Package.swift",
                   PACKAGE_SHIPPING_MANIFEST.replace('resources: [.copy("PrivacyInfo.xcprivacy")]',
                                                     'exclude: ["PrivacyInfo.xcprivacy"]'))
        self.write("swift/Packages/Mail/Sources/Mail/PrivacyInfo.xcprivacy", manifest())
        self.assertEqual(cpm.problems(self.root), [
            "Mail/Mail: swift/Packages/Mail/Sources/Mail/PrivacyInfo.xcprivacy is not a resource in "
            "swift/Packages/Mail/Package.swift, so it does not ship"])

    def test_a_package_manifest_that_misses_a_category_its_module_uses_fails(self) -> None:
        self.write("swift/Packages/Mail/Package.swift", PACKAGE_SHIPPING_MANIFEST)
        self.write("swift/Packages/Mail/Sources/Mail/Mail.swift", "let store = UserDefaults.standard\n")
        self.write("swift/Packages/Mail/Sources/Mail/PrivacyInfo.xcprivacy", manifest())
        self.assertEqual(cpm.problems(self.root), [
            f"Mail/Mail: swift/Packages/Mail/Sources/Mail/Mail.swift uses `{DEFAULTS}`, "
            "which swift/Packages/Mail/Sources/Mail/PrivacyInfo.xcprivacy does not declare"])

    def test_a_manifest_that_is_not_a_property_list_fails(self) -> None:
        self.write("swift/My Ext/PrivacyInfo.xcprivacy", "<plist><dict>")
        problems = cpm.problems(self.root)
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("My Ext: swift/My Ext/PrivacyInfo.xcprivacy is not a valid property list"))


if __name__ == "__main__":
    unittest.main()
