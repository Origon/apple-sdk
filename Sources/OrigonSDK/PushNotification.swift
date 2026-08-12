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
    /// Return mutable delivery content. A matching generation may copy the
    /// server-authorized title and preview. Missing or stale generation leaves
    /// the provider/APNs title and body unchanged.
    public static func contentForDelivery(
        _ content: UNNotificationContent,
        appGroupIdentifier: String? = nil
    ) -> UNMutableNotificationContent {
        let output = content.mutableCopy() as? UNMutableNotificationContent
            ?? UNMutableNotificationContent()
        let defaults = appGroupIdentifier.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        let copy = deliveryCopy(
            providerTitle: content.title,
            providerBody: content.body,
            userInfo: content.userInfo,
            currentGeneration: defaults.string(forKey: PushRegistrationStore.generationKey)
        )
        output.title = copy.title
        output.body = copy.body
        return output
    }
    #endif

    static func deliveryCopy(
        providerTitle: String,
        providerBody: String,
        userInfo: [AnyHashable: Any],
        currentGeneration: String?
    ) -> (title: String, body: String) {
        guard
            let remoteGeneration = userInfo["endpointGeneration"] as? String,
            currentGeneration == remoteGeneration
        else {
            return (providerTitle, providerBody)
        }

        let title = nonblankString(userInfo["title"]) ?? providerTitle
        let body = nonblankString(userInfo["preview"]) ?? providerBody
        return (title, body)
    }

    private static func nonblankString(_ value: Any?) -> String? {
        guard
            let value = value as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return value
    }
}
