import Foundation

/// Counts physical text-entry keystrokes, rather than composed Hangul syllables.
/// Stores counts only; no typed text or individual key history is retained.
public final class TypingStatistics: @unchecked Sendable {
    public struct Counts: Codable, Equatable, Sendable {
        public var typed = 0
        public var backspaces = 0

        public init(typed: Int = 0, backspaces: Int = 0) {
            self.typed = typed
            self.backspaces = backspaces
        }

        public var backspaceRatio: Double {
            typed == 0 ? 0 : Double(backspaces) / Double(typed)
        }
    }

    private struct State: Codable {
        var total = Counts()
        var today = Counts()
        var day: Date
        var daily: [String: Counts]?
    }

    public static var koreanCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    public func dayKey(at date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// Only records collected after this feature was installed; legacy totals stay separate.
    public func dailyHistory() -> [String: Counts] {
        lock.lock()
        defer { lock.unlock() }
        return state.daily ?? [:]
    }

    public static func combined(_ histories: [[String: Counts]]) -> [String: Counts] {
        var result: [String: Counts] = [:]
        for history in histories {
            for (day, counts) in history {
                var sum = result[day] ?? Counts()
                sum.typed += counts.typed
                sum.backspaces += counts.backspaces
                result[day] = sum
            }
        }
        return result
    }

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let storageKey = "typingStatistics.v1"
    private let lock = NSLock()
    private var state: State

    public init(defaults: UserDefaults = .standard, calendar: Calendar = TypingStatistics.koreanCalendar) {
        self.defaults = defaults
        self.calendar = calendar
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State(day: calendar.startOfDay(for: Date()))
        }
    }

    public func record(
        keyCode: UInt16, shift: Bool = false, shortcut: Bool = false,
        secure: Bool = false, at date: Date = Date()
    ) {
        guard !secure, !shortcut else { return }
        guard !(keyCode == Keymap.space && shift) else { return }
        let deleting = keyCode == Keymap.delete
        guard deleting || keyCode == Keymap.return || keyCode == Keymap.tab
            || Keymap.qwertyCharacter(keyCode: keyCode, shift: shift) != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        rollDay(at: date)
        let key = dayKey(at: date)
        var daily = state.daily ?? [:]
        var counts = daily[key] ?? Counts()
        if deleting {
            counts.backspaces += 1
            state.total.backspaces += 1
            state.today.backspaces += 1
        } else {
            counts.typed += 1
            state.total.typed += 1
            state.today.typed += 1
        }
        daily[key] = counts
        state.daily = daily
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: storageKey)
        }
    }

    public func snapshot(at date: Date = Date()) -> (today: Counts, total: Counts) {
        lock.lock()
        defer { lock.unlock() }
        rollDay(at: date)
        return (state.today, state.total)
    }

    private func rollDay(at date: Date) {
        let day = calendar.startOfDay(for: date)
        if day != state.day {
            state.day = day
            state.today = Counts()
        }
    }
}
