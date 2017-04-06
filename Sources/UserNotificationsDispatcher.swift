import Foundation
import UserNotifications

/// Dispatcher which is used to handler Push/Local/Custom user notifications. 
/// - note: All public methods are thread safe.
/// - note: Singleton by iOS design because `UNUserNotificationCenter` has only one instance in an iOS app.
public final class UserNotificationsDispatcher: NSObject {

  /// - notHandled: this notifications cannot be handled by the handler
  /// - handled: this notification has been handled by the handler
  public enum HandlerResult {
    case notHandled
    case handled(withOptions: UNNotificationPresentationOptions)

    public func merging(with otherResult: HandlerResult) -> HandlerResult {
      switch (self, otherResult) {
      case (.notHandled, _):
        return otherResult
      case (_, .notHandled):
        return self
      case (.handled(let options1), .handled(let options2)):
        return .handled(withOptions: options1.union(options2))
      default:
        fatalError("Not handled properly. Swift can't determine correct exhaustiveness of switch")
      }
    }
  }

  public struct Action {
    fileprivate let identifier: String

    public init(notificationResponse: UNNotificationResponse) {
      identifier = notificationResponse.actionIdentifier
    }
  }

  public typealias HandlerBlock<UserNotification: UserNotificationDescriptor>
    = (UserNotification, @escaping (HandlerResult) -> Void) -> Void

  public typealias ActionHandlerBlock<UserNotification: UserNotificationDescriptor>
    = (UserNotification, Action, @escaping () -> Void) -> Void

  private let rawTypeKey: String

  private var handlers: [RegistrationToken: Handler] = [:]
  private var actionHandlers: [UserNotificationRawType: ActionHandler] = [:]

  private let queue = DispatchQueue(label: "com.alexander_belyavskiy.UserNotificationsDispatcher",
                                    qos: .background)
  private lazy var userNotificationCenterDelegate: UNUserNotificationCenterDelegateImpl = {
    UNUserNotificationCenterDelegateImpl(dispatcher: self)
  }()

  internal init(rawTypeKey: String) {
    self.rawTypeKey = rawTypeKey
    super.init()
    UNUserNotificationCenter.current().delegate = userNotificationCenterDelegate
  }

  // MARK: - Registering

  /// Register to receive notifications right before notification UI is about to be presented
  ///
  /// - Parameters:
  ///   - handlerQueue: queue to call handler on
  ///   - handler: a handler to call before notification UI is about to be presented.
  /// - Returns: a token which is used in `unregister(_:)` method to remove handler from receiving notifications
  /// - note: You can add more than one handler for one `UserNotification`.
  public func register<UserNotification: UserNotificationDescriptor>(handlerQueue: DispatchQueue,
                       handler: @escaping HandlerBlock<UserNotification>) -> RegistrationToken {
    return queue.sync {
      let token = RegistrationToken()
      handlers[token] = Handler(queue: handlerQueue, handler: handler)
      return token
    }
  }

  /// Register to handler actions from notifications
  ///
  /// - Parameters:
  ///   - handlerQueue: queue to call handler on
  ///   - handler: a handler to call when user chosen an action from notification UI
  /// - note: You can only have one action handler per `UserNotification`. 
  ///         It is considered programmer error to use more than one action handler per UserNotification
  /// - seealso: `unregister(_:)`
  public func registerActionHandler<UserNotification: UserNotificationDescriptor>(handlerQueue: DispatchQueue,
                                    handler: @escaping ActionHandlerBlock<UserNotification>) {
    queue.sync {
      let notificationRawType = UserNotification.type
      assert(actionHandlers[notificationRawType] == nil, "Action handlers only makes sense for one to one usage")
      actionHandlers[notificationRawType] = ActionHandler(queue: handlerQueue, handler: handler)
    }
  }

  /// Unregister handler from receiving notifications
  ///
  /// - Parameter token: a token returned from `register` method
  public func unregister(_ token: RegistrationToken) {
    queue.sync {
      handlers[token] = nil
    }
  }

  /// Unregister action handler from receiving notifications for `UserNotification` actions
  ///
  /// - Parameter notificationType: a notification type used in `register` method
  public func unregisterActionHandler<UserNotification: UserNotificationDescriptor>(for notificationType: UserNotification.Type) {
    queue.sync {
      actionHandlers[notificationType.type] = nil
    }
  }

  public final class RegistrationToken: NSObject {}

  private func handlers(for notificationType: UserNotificationRawType) -> [Handler]? {
    let handlers = self.handlers.filter { $0.value.userNotificationRawType == notificationType }.map { $0.value }
    return handlers.count == 0 ? nil : handlers
  }

  // MARK: - Handle notifications

  public func handleRemoteNotification(userInfo: UserNotificationInfo) {
    guard let rawNotificationType = userInfo.rawType else { return }
    guard let handlers = handlers(for: rawNotificationType), handlers.count > 0 else {
      return
    }

    callHandlers(handlers, notificationInfo: userInfo, onGoingOptions: .notHandled, finalCompletionHandler: {_ in })
  }

  private func handle(_ response: UNNotificationResponse, completion: @escaping () -> Void) {
    dispatchPrecondition(condition: .onQueue(queue))

    let action = Action(notificationResponse: response)
    let notificationInfo = response.notification.notificationInfo(rawTypeKey: rawTypeKey)

    guard let notificationType = notificationInfo.rawType,
      let handler = actionHandlers[notificationType] else {
        completion();
        return
    }

    do {
      try handler.callHandler(with: notificationInfo, action: action, completion: completion)
    } catch {
      assertionFailure("Check why this happens: response: \(response), error: \(error)")
      completion()
    }
  }

  private func willPresent(_ notification: UNNotification,
                           completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    dispatchPrecondition(condition: .onQueue(queue))

    guard let rawNotificationType = notification.notificationInfo(rawTypeKey: rawTypeKey).rawType else { completionHandler([]); return }
    guard let handlers = handlers(for: rawNotificationType), handlers.count > 0 else {
      completionHandler([.alert, .sound, .badge])
      return
    }

    callHandlers(handlers,
                 notificationInfo: notification.notificationInfo(rawTypeKey: rawTypeKey),
                 onGoingOptions: .notHandled,
                 finalCompletionHandler: completionHandler)
  }

  private func callHandlers(_ handlers: [Handler],
                            notificationInfo: UserNotificationInfo,
                            onGoingOptions: HandlerResult,
                            finalCompletionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    var handlers = handlers
    guard let nextHandler = handlers.popLast() else {
      switch onGoingOptions {
      case .notHandled:
        finalCompletionHandler([.alert, .badge, .sound])
      case .handled(let options):
        finalCompletionHandler(options)
      }
      return
    }

    do {
      try nextHandler.callHandler(with: notificationInfo) { [weak self] (handlerResult) in
        let onGoingOptions = onGoingOptions.merging(with: handlerResult)
        self?.callHandlers(handlers,
                           notificationInfo: notificationInfo,
                           onGoingOptions: onGoingOptions,
                           finalCompletionHandler: finalCompletionHandler)
      }
    } catch {
      assertionFailure("Check why \(nextHandler) can't handler \(notificationInfo)")
      callHandlers(handlers, notificationInfo: notificationInfo, onGoingOptions: onGoingOptions, finalCompletionHandler: finalCompletionHandler)
    }
  }

  // MARK: - Impl UNUserNotificationCenterDelegate

  private final class UNUserNotificationCenterDelegateImpl: NSObject, UNUserNotificationCenterDelegate {
    private unowned let dispatcher: UserNotificationsDispatcher

    public init(dispatcher: UserNotificationsDispatcher) {
      self.dispatcher = dispatcher
      super.init()
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
      dispatcher.queue.async { [weak self] in
        self?.dispatcher.handle(response, completion: completionHandler)
      }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
      dispatcher.queue.async { [weak self] in
        self?.dispatcher.willPresent(notification, completionHandler: completionHandler)
      }
    }
  }

  private final class Handler {
    fileprivate let userNotificationRawType: UserNotificationRawType
    private let anyHandler: (UserNotificationInfo, @escaping (HandlerResult) -> Void) throws -> Void

    public init<UserNotification: UserNotificationDescriptor>
      (queue: DispatchQueue, handler: @escaping HandlerBlock<UserNotification>)
    {
      self.userNotificationRawType = UserNotification.type
      anyHandler = { (notification, completionHandler) in
        let notification = try UserNotification(notification)
        queue.async {
          handler(notification, completionHandler)
        }
      }
    }

    public func callHandler(with notificationInfo: UserNotificationInfo,
                            completionHandler: @escaping (HandlerResult) -> Void) throws {
      try anyHandler(notificationInfo, completionHandler)
    }
  }

  private final class ActionHandler {
    fileprivate let userNotificationRawType: UserNotificationRawType
    private let anyHandler: (UserNotificationInfo, Action, @escaping () -> Void) throws -> Void

    public init<UserNotification: UserNotificationDescriptor>
      (queue: DispatchQueue, handler: @escaping ActionHandlerBlock<UserNotification>)
    {
      self.userNotificationRawType = UserNotification.type
      anyHandler = { (notification, action, completionHandler) in
        let notification = try UserNotification(notification)
        queue.async {
          handler(notification, action, completionHandler)
        }
      }
    }

    public func callHandler(with notificationInfo: UserNotificationInfo,
                            action: Action,
                            completion: @escaping () -> Void) throws {
      try anyHandler(notificationInfo, action, completion)
    }
  }
}
