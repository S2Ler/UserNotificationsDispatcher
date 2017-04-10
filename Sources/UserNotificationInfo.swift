import Foundation

public struct UserNotificationInfo {
  public let userInfo: [String: Any]
  private let rawTypeKey: String

  public init(notificationUserInfo: [AnyHashable: Any], rawTypeKey: String) {
    self.rawTypeKey = rawTypeKey

    if let aps = notificationUserInfo as? [String: Any] {
      self.userInfo = aps
    } else {
      userInfo = [:]
    }
  }

  public var rawType: UserNotificationRawType?  {
    guard let type: UserNotificationRawType = apsValue(key: rawTypeKey) else { return nil }
    return type
  }

  public func apsValue<ValueType>(key: String) -> ValueType? {
    guard let aps = userInfo["aps"] as? [String: Any] else { return nil }

    if let value = aps[key] as? ValueType {
      return value
    } else {
      return nil
    }
  }
}
