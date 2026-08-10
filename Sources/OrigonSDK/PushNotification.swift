import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Generation gate shared by the app, its notification delegate, and an
/// optional Notification Service Extension.
public enum OrigonPushNotification {
    public static func isCurrent(
        userInfo: [AnyHashable: Any],
        appGroupIdentifier: String? = nil
    ) -> Bool {
        guard let remote = userInfo["endpointGeneration"] as? String else { return false }
        let defaults = appGroupIdentifier.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        return defaults.string(forKey: PushRegistrationStore.generationKey) == remote
    }

    public static func sessionId(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo["sessionId"] as? String
    }

    #if canImport(UserNotifications)
    /// Return mutable delivery content. A matching generation may show the
    /// sanitized preview; a mismatch is reduced to generic text.
    public static func contentForDelivery(
        _ content: UNNotificationContent,
        appGroupIdentifier: String? = nil
    ) -> UNMutableNotificationContent {
        let output = content.mutableCopy() as? UNMutableNotificationContent
            ?? UNMutableNotificationContent()
        guard isCurrent(userInfo: content.userInfo, appGroupIdentifier: appGroupIdentifier) else {
            output.title = "Origon"
            output.body = "New message"
            return output
        }
        if let preview = content.userInfo["preview"] as? String,
           !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output.body = preview
        }
        return output
    }
    #endif
}
