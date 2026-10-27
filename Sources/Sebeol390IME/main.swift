import AppKit
import Carbon
import InputMethodKit
import Sebeol390Core

private let bundleIdentifier = "com.ias.inputmethod.seto"
private let connectionName = bundleIdentifier + "_Connection"

if CommandLine.arguments.contains("--register") {
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    fputs("TISRegisterInputSource status \(status)\n", stderr)
    var enabled = false
    if let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] {
        for source in list {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyBundleID) else { continue }
            let value = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
            if value == bundleIdentifier {
                let enable = TISEnableInputSource(source)
                fputs("TISEnableInputSource status \(enable)\n", stderr)
                enabled = enable == noErr || enabled
            }
        }
    }
    if !enabled {
        fputs("새 앱 ID의 입력 소스가 아직 등록 목록에 없습니다. 로그아웃 후 다시 등록하세요.\n", stderr)
    }
    exit(status == noErr && enabled ? 0 : 1)
}

// Preserve local settings and statistics when upgrading from the original bundle ID.
private let migrationKey = "seto.bundleIDMigration.v1"
private let defaults = UserDefaults.standard
if !defaults.bool(forKey: migrationKey) {
    let current = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
    let legacy = defaults.persistentDomain(forName: "com.sebeol390.inputmethod.Sebeol390") ?? [:]
    for (key, value) in legacy where current[key] == nil {
        defaults.set(value, forKey: key)
    }
    defaults.set(true, forKey: migrationKey)
}

private let server: IMKServer = {
    guard let server = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier) else {
        fputs("IMKServer를 시작하지 못했습니다.\n", stderr)
        exit(1)
    }
    return server
}()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
StatisticsSync.shared.start()
withExtendedLifetime(server) {
    app.run()
}
