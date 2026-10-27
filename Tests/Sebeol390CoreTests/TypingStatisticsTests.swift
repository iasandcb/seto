import Foundation
import Testing
@testable import Sebeol390Core

@Test func typingStatisticsCountKeysAndPersistAcrossControllers() throws {
    let suite = "Sebeol390.TypingStatisticsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let statistics = TypingStatistics(defaults: defaults)
    // ㄱ + ㅏ are two physical keys even though they compose into one 가.
    for code: UInt16 in [0x28, 0x03, Keymap.space, Keymap.return, Keymap.tab] {
        statistics.record(keyCode: code)
    }
    for _ in 0..<2 { statistics.record(keyCode: Keymap.delete) }
    let saved = TypingStatistics(defaults: defaults).snapshot()
    #expect(saved.total.typed == 5)
    #expect(saved.total.backspaces == 2)
    #expect(saved.total.backspaceRatio == 0.4)
    #expect(saved.today == saved.total)
}

@Test func typingStatisticsExcludeShortcutsNavigationAndSecureInput() throws {
    let suite = "Sebeol390.TypingStatisticsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let statistics = TypingStatistics(defaults: defaults)
    statistics.record(keyCode: Keymap.space, shift: true)
    statistics.record(keyCode: 0x00, shortcut: true)
    statistics.record(keyCode: Keymap.delete, shortcut: true)
    statistics.record(keyCode: 0x00, secure: true)
    statistics.record(keyCode: Keymap.delete, secure: true)
    for code: UInt16 in [Keymap.escape, Keymap.capsLock, 0x7B, 0x75, 0x7A] {
        statistics.record(keyCode: code)
    }
    let empty = statistics.snapshot()
    #expect(empty.total.typed == 0)
    #expect(empty.total.backspaces == 0)
    #expect(empty.total.backspaceRatio == 0)
    // Each repeated keyDown counts, including Backspace on an empty buffer.
    statistics.record(keyCode: Keymap.delete)
    statistics.record(keyCode: Keymap.delete)
    statistics.record(keyCode: 0x00, shift: true)
    #expect(statistics.snapshot().total.backspaceRatio == 2)
}

@Test func typingStatisticsRollOverAtLocalMidnight() throws {
    let suite = "Sebeol390.TypingStatisticsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Seoul"))
    let before = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23, minute: 59)))
    let after = before.addingTimeInterval(120)
    let statistics = TypingStatistics(defaults: defaults, calendar: calendar)
    statistics.record(keyCode: 0x00, at: before)
    statistics.record(keyCode: Keymap.delete, at: before)
    #expect(statistics.snapshot(at: after).today.typed == 0)
    #expect(statistics.snapshot(at: after).today.backspaces == 0)
    statistics.record(keyCode: 0x00, at: after)
    let restored = TypingStatistics(defaults: defaults, calendar: calendar).snapshot(at: after)
    #expect(restored.today.typed == 1)
    #expect(restored.today.backspaces == 0)
    #expect(restored.total.typed == 2)
    #expect(restored.total.backspaces == 1)
}

@Test func dailyHistorySurvivesMidnightAndRestart() throws {
    let suite = "Sebeol390.DailyTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let before = try #require(ISO8601DateFormatter().date(from: "2026-10-26T14:59:00Z"))
    let after = before.addingTimeInterval(120)
    let store = TypingStatistics(defaults: defaults)
    store.record(keyCode: 0, at: before)
    store.record(keyCode: Keymap.delete, at: after)
    let restored = TypingStatistics(defaults: defaults).dailyHistory()
    #expect(restored["2026-10-26"]?.typed == 1)
    #expect(restored["2026-10-27"]?.backspaces == 1)
}

@Test func legacyCountsRemainSeparateFromNewDailyHistory() throws {
    let suite = "Sebeol390.LegacyTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    struct Legacy: Encodable {
        var total = TypingStatistics.Counts(typed: 100, backspaces: 10)
        var today = TypingStatistics.Counts(typed: 20, backspaces: 2)
        var day = TypingStatistics.koreanCalendar.startOfDay(for: Date())
    }
    defaults.set(try JSONEncoder().encode(Legacy()), forKey: "typingStatistics.v1")
    let store = TypingStatistics(defaults: defaults)
    #expect(store.snapshot().total.typed == 100)
    #expect(store.dailyHistory().isEmpty)
    store.record(keyCode: 0)
    #expect(store.snapshot().total.typed == 101)
    #expect(store.dailyHistory().values.first?.typed == 1)
}

@Test func combinedRatioUsesSummedCounts() {
    let day = "2026-10-27"
    let histories = [
        [day: TypingStatistics.Counts(typed: 100, backspaces: 10)],
        [day: TypingStatistics.Counts(typed: 900, backspaces: 9)],
        [day: TypingStatistics.Counts(typed: 0, backspaces: 1)]
    ]
    let sum = TypingStatistics.combined(histories)[day]
    #expect(sum?.typed == 1000)
    #expect(sum?.backspaces == 20)
    #expect(sum?.backspaceRatio == 0.02)
}
