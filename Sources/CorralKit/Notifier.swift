import AppKit
import CorralCore
import UserNotifications

/// One notification. A later one with the same id replaces it (one per session in Notification Center).
public struct CorralNote: Equatable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var sound: Bool
    /// Clicking the notification opens this session.
    public var session: UUID?
    /// A Claude permission prompt this note can answer (Allow / Deny buttons): the prompt's token,
    /// checked again before anything is typed.
    public var prompt: String?

    public init(id: String, title: String, subtitle: String, body: String, sound: Bool, session: UUID?,
                prompt: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sound = sound
        self.session = session
        self.prompt = prompt
    }
}

/// Notification Center access. `.system` asks for permission the first time there is something to show
/// (not at launch; that first note is dropped); tests swap in a recorder.
public struct Notifier {
    public enum Permission: Equatable { case allowed, denied, undecided }

    public var post: (CorralNote) -> Void
    public var withdraw: (_ ids: [String]) -> Void
    /// The current permission, delivered on the main queue.
    public var permission: (@escaping (Permission) -> Void) -> Void
    /// Shows the system prompt when undecided; the outcome on the main queue.
    public var requestPermission: (@escaping (Permission) -> Void) -> Void

    public init(post: @escaping (CorralNote) -> Void, withdraw: @escaping ([String]) -> Void,
                permission: @escaping (@escaping (Permission) -> Void) -> Void,
                requestPermission: @escaping (@escaping (Permission) -> Void) -> Void) {
        self.post = post
        self.withdraw = withdraw
        self.permission = permission
        self.requestPermission = requestPermission
    }

    static func permission(_ status: UNAuthorizationStatus) -> Permission {
        switch status {
        case .notDetermined: return .undecided
        case .denied: return .denied
        default: return .allowed
        }
    }

    static let options: UNAuthorizationOptions = [.alert, .sound]

    static let permissionCategory = "corral.permission"
    static let allowAction = "corral.allow"
    static let denyAction = "corral.deny"

    /// Allow / Deny on permission prompts. Allow answers in the background (unlocked Mac only);
    /// Deny brings Corral forward, as Claude then asks what to do instead.
    static var categories: Set<UNNotificationCategory> {
        let allow = UNNotificationAction(identifier: allowAction, title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: denyAction, title: "Deny", options: [.destructive, .foreground])
        return [UNNotificationCategory(identifier: permissionCategory, actions: [allow, deny], intentIdentifiers: [])]
    }

    /// The request for `note`: its session in `userInfo` (a click opens it) and as the thread (grouped).
    static func request(_ note: CorralNote) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.subtitle = note.subtitle
        content.body = note.body
        if note.sound { content.sound = .default }
        if let session = note.session {
            content.userInfo = ["session": session.uuidString]
            content.threadIdentifier = session.uuidString
            if let prompt = note.prompt {
                content.userInfo["prompt"] = prompt
                content.categoryIdentifier = permissionCategory
            }
        }
        return UNNotificationRequest(identifier: note.id, content: content, trigger: nil)
    }

    public static let system = Notifier(post: { note in
        let request = request(note)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // The prompt waits for the user; by then this note may be stale (answered, withdrawn).
                center.requestAuthorization(options: options) { _, _ in }
            case .denied:
                break
            default:
                center.add(request)
            }
        }
    }, withdraw: { ids in
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }, permission: { done in
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let p = permission(settings.authorizationStatus)
            DispatchQueue.main.async { done(p) }
        }
    }, requestPermission: { done in
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: options) { _, _ in
            center.getNotificationSettings { settings in
                let p = permission(settings.authorizationStatus)
                DispatchQueue.main.async { done(p) }
            }
        }
    })

    /// System Settings › Notifications, at Corral's entry when the bundle has an id.
    static var settingsURL: URL {
        let id = Bundle.main.bundleIdentifier.map { "?id=\($0)" } ?? ""
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension\(id)")!
    }
}
