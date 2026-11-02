import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct FreshInstallKeychainPurgeTests {
    @Test("a delete that fails leaves the install marker unset, so the next launch purges again")
    func aFailedDeleteIsTriedAgainAtTheNextLaunch() async {
        let installed = AppConstants.UserDefaultsKeys.appHasBeenInstalled
        await withExclusiveRealDefaults {
            let saved = UserDefaults.standard.object(forKey: installed)
            defer { UserDefaults.standard.set(saved, forKey: installed) }
            UserDefaults.standard.removeObject(forKey: installed)
            var tried: Set<String> = []

            let first = FreshInstallKeychainPurge.runIfFreshInstall {
                tried.insert($0)
                return $0 != AuthTokenManager.refreshTokenKey
            }

            #expect(first == .itemsLeft)
            #expect(first.isFreshInstall)
            #expect(tried.contains(AuthTokenManager.accessTokenKey) && tried.contains(AuthTokenManager.departingSessionKey))
            #expect(!Defaults[.appHasBeenInstalled])
            #expect(FreshInstallKeychainPurge.runIfFreshInstall { _ in true } == .purged)
            #expect(Defaults[.appHasBeenInstalled])
            #expect(FreshInstallKeychainPurge.runIfFreshInstall { _ in
                Issue.record("an installed app deleted a Keychain item")
                return true
            } == .installedBefore)
        }
    }

    @Test("a reinstall keeps the device id and its secret, so the app announces as the same device")
    func aReinstallKeepsTheDeviceIdAndSecret() async {
        let installed = AppConstants.UserDefaultsKeys.appHasBeenInstalled
        await withExclusiveRealDefaults {
            let saved = UserDefaults.standard.object(forKey: installed)
            defer { UserDefaults.standard.set(saved, forKey: installed) }
            UserDefaults.standard.removeObject(forKey: installed)
            var deleted: Set<String> = []

            #expect(FreshInstallKeychainPurge.runIfFreshInstall { deleted.insert($0); return true } == .purged)

            #expect(deleted.contains(AuthTokenManager.refreshTokenKey))
            #expect(!deleted.contains(AppConstants.KeychainKeys.pushDeviceId))
            #expect(!deleted.contains(AppConstants.KeychainKeys.pushDeviceSecret))
        }
    }
}
