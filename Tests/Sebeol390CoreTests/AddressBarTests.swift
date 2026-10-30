import Testing
@testable import Sebeol390Core

@Test func safariAddressFieldIsRecognizedByIdentifier() {
    let field = FocusedElement(role: "AXTextField", identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD", insideWebArea: false)
    #expect(AddressBar.contains(field, bundleIdentifier: "com.apple.Safari"))
}

@Test func chromeOmniboxIsANativeTextField() {
    let omnibox = FocusedElement(role: "AXTextField", insideWebArea: false)
    #expect(AddressBar.contains(omnibox, bundleIdentifier: "com.google.Chrome"))
    #expect(AddressBar.contains(FocusedElement(role: "AXComboBox", insideWebArea: false),
                                bundleIdentifier: "com.google.Chrome"))
}

@Test func webPageFieldsKeepAutomaticConversion() {
    for bundle in ["com.apple.Safari", "com.google.Chrome"] {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXWebArea"] {
            #expect(!AddressBar.contains(FocusedElement(role: role, insideWebArea: true), bundleIdentifier: bundle))
        }
    }
}

@Test func otherAppsAndElementsAreUnchanged() {
    let field = FocusedElement(role: "AXTextField", identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD", insideWebArea: false)
    for bundle: String? in ["com.apple.TextEdit", "com.apple.Terminal", "org.mozilla.firefox", nil] {
        #expect(!AddressBar.contains(field, bundleIdentifier: bundle))
    }
    #expect(!AddressBar.contains(FocusedElement(role: "AXTextArea", insideWebArea: false), bundleIdentifier: "com.google.Chrome"))
    #expect(!AddressBar.contains(FocusedElement(role: nil, insideWebArea: false), bundleIdentifier: "com.apple.Safari"))
    #expect(!AddressBar.contains(FocusedElement(role: "AXTextField", subrole: "AXSecureTextField", insideWebArea: false),
                                 bundleIdentifier: "com.apple.Safari"))
}
