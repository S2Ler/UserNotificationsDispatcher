import Foundation
import UserNotifications

public extension UNNotification {
  public func notificationInfo(rawTypeKey: String) -> UserNotificationInfo {
    return UserNotificationInfo(notificationUserInfo: request.content.userInfo,
                                rawTypeKey: rawTypeKey)
  }
}
