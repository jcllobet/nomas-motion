import Foundation
import ServiceManagement

enum LaunchAtLoginController {
    private static let canonicalBundlePath = "/Applications/Nomas Motion.app"
    private static let registeredBundlePathKey = "NomasMotion.LoginItemRegisteredBundlePath"
    private static let registeredBundleIdentifierKey = "NomasMotion.LoginItemRegisteredBundleIdentifier"

    static func registerIfAppropriate() -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NOMAS_MOTION_SKIP_LOGIN_ITEM"] != "1" else {
            return nil
        }

        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app", isCanonicalInstalledApp(bundleURL) else {
            return nil
        }

        do {
            let status = SMAppService.mainApp.status
            if status == .enabled {
                markRegistered(bundleURL)
                return nil
            }
            if status == .requiresApproval {
                clearRegistrationMarker()
                return nil
            }

            // ServiceManagement is the source of truth. A persisted marker
            // must never suppress recovery after approval is denied, the
            // service is removed, or the bundle is replaced.
            clearRegistrationMarker()
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .enabled {
                markRegistered(bundleURL)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func unregister() -> String? {
        do {
            try SMAppService.mainApp.unregister()
            clearRegistrationMarker()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func isCanonicalInstalledApp(_ bundleURL: URL) -> Bool {
        bundleURL.standardizedFileURL.path == URL(fileURLWithPath: canonicalBundlePath).standardizedFileURL.path
    }

    private static func markRegistered(_ bundleURL: URL) {
        let defaults = UserDefaults.standard
        defaults.set(bundleURL.standardizedFileURL.path, forKey: registeredBundlePathKey)
        defaults.set(Bundle.main.bundleIdentifier, forKey: registeredBundleIdentifierKey)
    }

    private static func clearRegistrationMarker() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: registeredBundlePathKey)
        defaults.removeObject(forKey: registeredBundleIdentifierKey)
    }
}
