import AppKit
import Carbon
import SetoCore

/// A session event tap that keeps Return, Enter, Esc, Tab and ⇧⇥ away from
/// the client while the refinement panel is open.
///
/// Chromium-based clients (Chrome, Electron) forward a keyDown to the page
/// even when the input method returns true from handle(_:client:), unless the
/// input method inserted or marked text during that event. The tap removes
/// those keys before any app sees them and reports them through `onKey`.
///
/// Every key the tap consumes is also consumed until its keyUp, including
/// auto-repeats, so a key held across the panel closing does not leak. After
/// `finish()` the tap only waits for those keyUps and then removes itself.
///
/// The tap runs on the main run loop, so all state is touched from the main
/// thread only.
final class RefinementKeyTap: @unchecked Sendable {
    /// Gives up waiting for keyUps after this long.
    private static let releaseTimeout: TimeInterval = 1.0

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var held: Set<UInt16> = []
    private var finishing = false
    private let onKey: (RefinementPanelKey) -> Void
    /// The timestamp of the last keyDown consumed here, so the IMK path can
    /// ignore the same event if it ever sees it too.
    private(set) var lastConsumedKeyDown: CGEventTimestamp?

    var isInstalled: Bool { port != nil }

    /// Returns nil when the tap cannot be created, e.g. without the
    /// Accessibility permission. `onKey` runs on the main thread after the
    /// event has been consumed.
    static func install(onKey: @escaping (RefinementPanelKey) -> Void) -> RefinementKeyTap? {
        let tap = RefinementKeyTap(onKey: onKey)
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        // The C callback cannot capture; it finds the tap through userInfo.
        // The tap object outlives its port: deinit invalidates the port.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<RefinementKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                return tap.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(tap).toOpaque()
        ) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        tap.port = port
        tap.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return tap
    }

    private init(onKey: @escaping (RefinementPanelKey) -> Void) {
        self.onKey = onKey
    }

    deinit {
        invalidate()
    }

    /// The panel opened again before the tap was removed.
    func resume() {
        finishing = false
    }

    /// The panel closed. Removes the tap once consumed keys are released.
    func finish() {
        guard isInstalled, !finishing else { return }
        finishing = true
        if held.isEmpty {
            invalidate()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseTimeout) { [weak self] in
            guard let self, self.finishing else { return }
            self.invalidate()
        }
    }

    func invalidate() {
        held = []
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let port {
            CFMachPortInvalidate(port)
        }
        source = nil
        port = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        case .keyDown, .keyUp:
            break
        default:
            return pass
        }
        guard isInstalled else { return pass }
        if IsSecureEventInputEnabled() {
            // The IMK path closes the panel on the next key.
            return pass
        }
        // Our own synthesized ⇧⌘← and anything else posted by this process
        // is not user input for the panel.
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
            return pass
        }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyUp {
            if held.remove(keyCode) != nil {
                if finishing, held.isEmpty {
                    // Not from inside the callback that is using the port.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.finishing else { return }
                        self.invalidate()
                    }
                }
                return nil
            }
            // A stray keyUp of a panel key while the panel is open.
            return !finishing && RefinementPanelKey.isPanelKey(keyCode) ? nil : pass
        }

        // keyDown: a key we already consumed, still held (auto-repeat).
        if held.contains(keyCode) {
            return nil
        }
        guard !finishing else { return pass }
        let flags = event.flags
        let action = RefinementPanelKey.action(
            keyCode: keyCode,
            command: flags.contains(.maskCommand),
            control: flags.contains(.maskControl),
            option: flags.contains(.maskAlternate),
            shift: flags.contains(.maskShift)
        )
        // Other keys reach the input method, which closes the panel.
        guard action != .other else { return pass }
        held.insert(keyCode)
        lastConsumedKeyDown = event.timestamp
        DispatchQueue.main.async { [weak self] in
            self?.onKey(action)
        }
        return nil
    }
}
