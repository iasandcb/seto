import Foundation
import Testing
#if SETO_ORACLE
@testable import SetoOracle
#else
@testable import SetoCore
#endif

@Test func unixCommandsAreInBundledLexicon() throws {
    let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")
    let lexicon = try Lexicon.load(from: resources)
    for command in ["chmod", "chown", "xargs", "rsync", "launchctl", "systemctl", "awk", "sed", "grep", "zsh", "ssh-keygen", "apt-get"] {
        #expect(lexicon.isEnglishWord(command))
        #expect(lexicon.isEnglishPrefix(String(command.prefix(3))))
    }
    #expect(lexicon.koreanWordCount > 0)
    #expect(lexicon.validKoreanWordCount > 0)
}

@Test func regularPluralFormsAlsoHaveTypingPrefixes() {
    let lexicon = Lexicon(english: ["command", "directory", "box", "batch", "process", "key"], korean: [])
    for word in ["commands", "directories", "boxes", "batches", "processes", "keys"] {
        #expect(lexicon.isEnglishWord(word))
        #expect(lexicon.isEnglishWord(word.uppercased()))
        for length in 1...word.count {
            #expect(lexicon.isEnglishPrefix(String(word.prefix(length))))
        }
    }
    #expect(!lexicon.isEnglishWord("directorys"))
    #expect(!lexicon.isEnglishWord("keyies"))
}
