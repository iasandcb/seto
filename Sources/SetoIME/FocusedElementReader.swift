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
            if !prompted {
                prompted = true
                // The value of kAXTrustedCheckOptionPrompt, which Swift 6
                // treats as shared mutable state.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            return false
        }
        guard let element = focused(bundleIdentifier: bundleIdentifier) else { return false }
        return AddressBar.contains(element, bundleIdentifier: bundleIdentifier)
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
