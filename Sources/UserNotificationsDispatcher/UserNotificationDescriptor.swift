import Foundation
import UserNotifications

public typealias UserNotificationRawType = String

public protocol UserNotificationDescriptor {
  static var type: UserNotificationRawType { get }
  init(_ notificationInfo: UserNotificationInfo) throws
}
