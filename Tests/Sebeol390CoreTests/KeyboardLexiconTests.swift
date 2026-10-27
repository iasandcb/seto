import Foundation
import Testing
@testable import Sebeol390Core

@Test func mappedKeyboardLexiconMatchesDesktop() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let desktop = try Lexicon.load(from: root.appendingPathComponent("Resources"))
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    for name in ["keyboard-english.txt", "keyboard-korean-valid.txt"] {
        try FileManager.default.copyItem(at: root.appendingPathComponent("iOS/Keyboard/Resources/" + name), to: bundle.appendingPathComponent(name))
    }
    try FileManager.default.copyItem(at: root.appendingPathComponent("Resources/korean-words.txt"), to: bundle.appendingPathComponent("korean-words.txt"))
    let keyboard = try Lexicon.loadForKeyboard(from: bundle)
    for word in ["hello", "world", "baby", "babies", "boxes", "cats", "API", "ios", "zzzznonword"] {
        #expect(keyboard.isEnglishWord(word) == desktop.isEnglishWord(word))
        #expect(keyboard.isEnglishPrefix(word) == desktop.isEnglishPrefix(word))
    }
    #expect(!keyboard.isEnglishPrefix(""))
    #expect(keyboard.validKoreanWordCount == desktop.validKoreanWordCount)
    for word in ["안녕하세요", "사람", "키보드", "없는없는단어"] {
        #expect(keyboard.isValidKorean(word) == desktop.isValidKorean(word))
        #expect(keyboard.isKoreanWord(word) == desktop.isKoreanWord(word))
    }
    #expect(Set(keyboard.englishWords(length: 1...4)) == Set(desktop.englishWords(length: 1...4)))
}
