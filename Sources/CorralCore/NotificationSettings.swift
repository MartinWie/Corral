import Foundation

/// What Corral posts a notification for (Settings › Notifications).
public enum NotificationKind: String, CaseIterable, Sendable {
    /// An agent wants to run a command, edit a file or use a tool.
    case permission
    /// An agent asks something, shows a plan, or waits on a prompt.
    case question
    /// A turn ended: the agent waits for a follow-up.
    case finished
    /// A turn stopped on an error.
    case failed
    /// A shell command that ran for a while ended.
    case command
}

/// Per-kind switches and sounds, and whether notifications also come while Corral is the active app.
public struct NotificationSettings: Codable, Equatable, Sendable {
    public struct Rule: Codable, Equatable, Sendable {
        public var on: Bool
        public var sound: Bool

        public init(on: Bool, sound: Bool) {
            self.on = on
            self.sound = sound
        }
    }

    /// Keyed by `NotificationKind.rawValue`; a kind with no entry has its default. Kinds a newer
    /// version added survive a round trip through this one.
    private var rules: [String: Rule] = [:]
    /// Also while Corral is in front (for sessions other than the one on screen).
    public var whileActive = true
    /// The command, file or question in the body; off: the session's directory only (banners and the
    /// lock screen show the body).
    public var showDetails = true

    public init() {}

    /// Everything on; the two that wait on the user also play a sound.
    public static func defaultRule(_ kind: NotificationKind) -> Rule {
        switch kind {
        case .permission, .question: return Rule(on: true, sound: true)
        case .finished, .failed, .command: return Rule(on: true, sound: false)
        }
    }

    public subscript(kind: NotificationKind) -> Rule {
        get { rules[kind.rawValue] ?? Self.defaultRule(kind) }
        set { rules[kind.rawValue] = newValue == Self.defaultRule(kind) ? nil : newValue }
    }

    enum CodingKeys: String, CodingKey { case rules, whileActive, showDetails }

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Rule by rule: one damaged or reshaped entry falls back to its default without taking the others along.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let r = try? c.nestedContainer(keyedBy: Key.self, forKey: .rules) {
            for key in r.allKeys {
                guard let rule = try? r.decode(Rule.self, forKey: key) else { continue }
                if let kind = NotificationKind(rawValue: key.stringValue) {
                    self[kind] = rule
                } else {
                    rules[key.stringValue] = rule
                }
            }
        }
        whileActive = (try? c.decodeIfPresent(Bool.self, forKey: .whileActive)) ?? true
        showDetails = (try? c.decodeIfPresent(Bool.self, forKey: .showDetails)) ?? true
    }
}
