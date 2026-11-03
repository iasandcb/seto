/// Accessibility facts about the focused element, read by the input method.
public struct FocusedElement: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    /// The element itself or one of its ancestors is page content (`AXWebArea`).
    public var insideWebArea: Bool

    public init(role: String?, subrole: String? = nil, identifier: String? = nil, insideWebArea: Bool) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.insideWebArea = insideWebArea
    }
}

/// URLs and search terms in a browser's address bar are not prose, so automatic
/// conversion and typo correction stay off there. Text fields on web pages are
/// unchanged.
public enum AddressBar {
    public static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome"]
    /// Safari's unified address and search field.
    static let safariIdentifier = "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
    private static let textRoles: Set<String> = ["AXTextField", "AXComboBox"]

    public static func isBrowser(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(browsers.contains) ?? false
    }

    /// Safari names its field. Chrome's omnibox has no stable identifier and a
    /// localized description, so a native text field outside page content
    /// counts as the address bar.
    public static func contains(_ element: FocusedElement, bundleIdentifier: String?) -> Bool {
        guard isBrowser(bundleIdentifier), !element.insideWebArea else { return false }
        if element.identifier == safariIdentifier { return true }
        guard let role = element.role, textRoles.contains(role) else { return false }
        return element.subrole != "AXSecureTextField"
    }
}
