import AppKit
import ApplicationServices
import Sebeol390Core

/// Reads the system-wide focused element through Accessibility. Without the
/// Accessibility permission this returns nil and nothing changes.
enum FocusedElementReader {
    nonisolated(unsafe) private static var prompted = false

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
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        guard let value = attribute(system, kAXFocusedUIElementAttribute) else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleIdentifier
        else { return nil }
        let role = attribute(element, kAXRoleAttribute) as? String
        return FocusedElement(
            role: role,
            subrole: attribute(element, kAXSubroleAttribute) as? String,
            identifier: attribute(element, kAXIdentifierAttribute) as? String,
            insideWebArea: role == "AXWebArea" || hasWebAreaAncestor(element)
        )
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
