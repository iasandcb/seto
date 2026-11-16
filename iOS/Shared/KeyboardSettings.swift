import Foundation

enum OneHandedLayout: String, CaseIterable {
    case off, left, right

    var title: String {
        switch self {
        case .off: return "끔"
        case .left: return "왼쪽"
        case .right: return "오른쪽"
        }
    }
}

/// The app writes; the keyboard only reads (no Full Access required).
@MainActor
enum KeyboardSettings {
    static let appGroup = "group.com.ias.seto"
    static let oneHandedKey = "keyboard.oneHandedLayout"
    static let defaults = UserDefaults(suiteName: appGroup)!

    static func oneHandedLayout(in defaults: UserDefaults = defaults) -> OneHandedLayout {
        OneHandedLayout(rawValue: defaults.string(forKey: oneHandedKey) ?? "") ?? .off
    }
}
