import OrigonSDK
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        // The helper copies server title/preview only for the locally current
        // endpoint generation. Stale or missing generations, and absent/blank
        // rich fields, preserve the original APNs alert content.
        let content = OrigonPushNotification.contentForDelivery(
            request.content,
            appGroupIdentifier: "group.com.example.app"
        )
        contentHandler(content)
    }
}
