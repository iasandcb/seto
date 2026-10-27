import AppKit
import Foundation
import Testing

// Mock IMK clients bypass macOS's input-source registration. Validate the bundle
// contract too: a selectable source needs a visible Unicode mode and a real icon.
@Test func inputMethodRegistersAVisibleUnicodeMode() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let resources = root.appendingPathComponent("Resources")
    let data = try Data(contentsOf: resources.appendingPathComponent("Info.plist"))
    let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let bundleID = try #require(plist["CFBundleIdentifier"] as? String)
    let modes = try #require(plist["tsInputModeListKey"] as? [String: [String: Any]])
    let visible = modes.filter { $0.value["tsInputModeIsVisibleKey"] as? Bool == true }
    #expect(!visible.isEmpty)
    #expect(visible.values.contains { $0["tsInputModeDefaultStateKey"] as? Bool == true })
    for (id, mode) in visible {
        #expect(id.hasPrefix(bundleID + "."))
        #expect(mode["TISInputSourceID"] as? String == id)
        #expect(mode["tsInputModeScriptKey"] as? String == "smUnicodeScript")
        #expect(mode["TISIntendedLanguage"] as? String == "ko")
        #expect((mode["tsInputModeCharacterRepertoireKey"] as? [String])?.contains("Hang") == true)
        let icon = try #require(mode["tsInputModeMenuIconFileKey"] as? String)
        #expect(NSImage(contentsOf: resources.appendingPathComponent(icon)) != nil)
    }
    let icon = try #require(plist["tsInputMethodIconFileKey"] as? String)
    #expect(NSImage(contentsOf: resources.appendingPathComponent(icon)) != nil)
}
