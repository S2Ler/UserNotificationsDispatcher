import Foundation

public struct UserNotificationInfo {
  public let aps: [String: Any]
  private let rawTypeKey: String

  public init(notificationUserInfo: [AnyHashable: Any], rawTypeKey: String) {
    self.rawTypeKey = rawTypeKey

    if let aps = notificationUserInfo as? [String: Any] {
      self.aps = aps
    } else {
      aps = [:]
    }
  }

  public var rawType: UserNotificationRawType?  {
    guard let type = aps[rawTypeKey] as? UserNotificationRawType else { return nil }
    return type
  }
}
