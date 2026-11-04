import AppKit
import ApplicationServices
import SetoCore

/// Reads the system-wide focused element through Accessibility. Without the
/// Accessibility permission this returns nil and nothing changes.
enum FocusedElementReader {
    nonisolated(unsafe) private static var prompted = false
    nonisolated(unsafe) private static var enabledPID: pid_t = 0

    static func addressBarFocused(bundleIdentifier: String?) -> Bool {
        guard AddressBar.isBrowser(bundleIdentifier) else { return false }
        if !AXIsProcessTrusted() {
            // Ask once per launch, and only when a browser is in use.
            requestTrustIfNeeded()
            return false
        }
        guard let element = focused(bundleIdentifier: bundleIdentifier) else { return false }
        return AddressBar.contains(element, bundleIdentifier: bundleIdentifier)
    }

    /// Shows the system Accessibility prompt at most once per launch.
    static func requestTrustIfNeeded() {
        guard !prompted, !AXIsProcessTrusted() else { return }
        prompted = true
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6
        // treats as shared mutable state.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// The focused element's selected text, if Accessibility exposes it.
    static func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        guard let application = attribute(system, kAXFocusedApplicationAttribute),
              let element = attribute(application as! AXUIElement, kAXFocusedUIElementAttribute) else { return nil }
        return attribute(element as! AXUIElement, kAXSelectedTextAttribute) as? String
    }

    static func textContext() -> AccessibilityTextContext? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        guard let applicationValue = attribute(system, kAXFocusedApplicationAttribute) else { return nil }
        let application = applicationValue as! AXUIElement
        guard let elementValue = attribute(application, kAXFocusedUIElementAttribute),
              let selectionValue = attribute(elementValue as! AXUIElement, kAXSelectedTextRangeAttribute) else { return nil }
        let element = elementValue as! AXUIElement
        var selection = CFRange()
        guard AXValueGetValue(selectionValue as! AXValue, .cfRange, &selection),
              selection.location >= 0, selection.length >= 0 else { return nil }
        if let text = attribute(element, kAXValueAttribute) as? String {
            return AccessibilityTextContext(
                element: element,
                document: text,
                selection: NSRange(location: selection.location, length: selection.length),
                documentStart: 0
            )
        }
        guard let number = attribute(element, kAXNumberOfCharactersAttribute) as? NSNumber else { return nil }
        let count = number.intValue
        let start = max(0, selection.location - 2_048)
        let end = min(count, selection.location + selection.length + 2_048)
        let range = NSRange(location: start, length: end - start)
        guard let text = string(for: range, in: element), (text as NSString).length == range.length else { return nil }
        return AccessibilityTextContext(
            element: element,
            document: text,
            selection: NSRange(location: selection.location - start, length: selection.length),
            documentStart: start
        )
    }

    static func select(_ range: NSRange, in element: AXUIElement) -> Bool {
        var value = CFRange(location: range.location, length: range.length)
        guard let selection = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, selection) == .success
    }

    private static func string(for range: NSRange, in element: AXUIElement) -> String? {
        var value = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &value) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &result
        ) == .success else { return nil }
        return result as? String
    }

    private static func focused(bundleIdentifier: String?) -> FocusedElement? {
        // Ask the browser itself. The system-wide focused element fails with
        // kAXErrorCannotComplete for Chrome, while its application element
        // answers.
        guard let pid = processIdentifier(bundleIdentifier) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // Chrome builds its native accessibility tree only for assistive
        // clients; this asks it to keep the tree. Other apps ignore it.
        if bundleIdentifier == "com.google.Chrome", enabledPID != pid {
            enabledPID = pid
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        // A cold tree can take longer than 0.1s on the first query.
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let value = attribute(app, kAXFocusedUIElementAttribute) else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        let role = attribute(element, kAXRoleAttribute) as? String
        return FocusedElement(
            role: role,
            subrole: attribute(element, kAXSubroleAttribute) as? String,
            identifier: attribute(element, kAXIdentifierAttribute) as? String,
            insideWebArea: role == "AXWebArea" || hasWebAreaAncestor(element)
        )
    }

    /// The frontmost app when it is the client, otherwise its first instance.
    private static func processIdentifier(_ bundleIdentifier: String?) -> pid_t? {
        guard let bundleIdentifier else { return nil }
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleIdentifier {
            return front.processIdentifier
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier
    }

    private static func hasWebAreaAncestor(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<64 {
            guard let value = attribute(current, kAXParentAttribute) else { return false }
            let parent = value as! AXUIElement
            let role = attribute(parent, kAXRoleAttribute) as? String
            if role == "AXWebArea" { return true }
            if role == kAXWindowRole || role == kAXApplicationRole { return false }
            current = parent
        }
        return false
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

struct AccessibilityTextContext {
    let element: AXUIElement
    let document: String
    let selection: NSRange
    let documentStart: Int
}
