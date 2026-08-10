import OrigonSDK
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let content = OrigonPushNotification.contentForDelivery(
            request.content,
            appGroupIdentifier: "group.com.example.app"
        )
        contentHandler(content)
    }
}
