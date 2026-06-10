import SwiftUI
import UIKit
import UserNotifications
import OrigonSDK

@main
struct OrigonSDKExampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sdk = SDKManager()

    init() {
        #if DEBUG
        OrigonClient.initLogging()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sdk)
        }
    }
}

/// Reference push-notification wiring.
///
/// The SDK only needs the raw APNs token; requesting notification
/// authorization and registering with APNs stays the host app's
/// responsibility (it owns the `aps-environment` entitlement and the user
/// prompt). Forward the token to
/// `OrigonClient.registerForPushNotifications(deviceToken:)` — it is safe
/// to call before the SDK is initialized, since the token is buffered and
/// sent automatically once the client exists.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                guard granted else { return }
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        OrigonClient.registerForPushNotifications(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed: \(error.localizedDescription)")
    }
}
