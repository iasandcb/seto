import Foundation
import Testing
@testable import Sebeol390Core

private let lexicon: Lexicon = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources")
    return try! Lexicon.load(from: root)
}()

@Test func ibryeokStaysKorean() {
    // 력 is y e x, and "yex" is an English word. The syllable must not be stolen.
    assertTypes("jd3yex", "입력")
    assertTypes("jd3yex ", "입력 ")
    for word in ["입력", "모르다", "됐다"] {
        let keys = SebeolKeys.keys(for: word)!
        assertTypes(keys, word)
    }
}

@Test func thanksStaysKorean() {
    let keys = SebeolKeys.keys(for: "고맙습니다")!
    assertTypes(keys, "고맙습니다")
    assertTypes(keys + "B", "고맙습니다!")
    #expect(clientFailures(keys + "B", "고맙습니다!", mode: .korean).isEmpty)
}

@Test func tentativeReadingsDoNotChangeMode() {
    for key: Character in ["x", "a", "5", "d"] {
        let session = Session(lexicon: lexicon, mode: .korean)
        let update = session.input(key)
        #expect(update.mode == .korean)
        #expect(session.mode == .korean)
        _ = session.backspace()
        #expect(session.mode == .korean)
        _ = session.input(key)
        _ = session.commitDisplayed()
        #expect(session.mode == .korean)
        #expect(session.type("M") == "\(key)1")
    }
    // A dictionary prefix alone does not select the next keyboard layout.
    let session = Session(lexicon: Lexicon(english: ["deployment"], korean: []))
    _ = session.type("dep")
    #expect(session.document == "dep")
    #expect(session.mode == .korean)
}

@Test func englishModeSurvivesSyllableShapedWords() {
    for word in ["of", "to", "in", "md", "yex"] {
        let session = Session(lexicon: lexicon, mode: .english)
        var paper = Paper()
        var typed = ""
        for key in word {
            typed.append(key)
            paper.apply(session.input(key).field)
            #expect(paper.text == typed, "\(session.debugLine)")
            #expect(session.mode == .english)
            #expect(paper.marked.isEmpty)
        }
        paper.apply(session.input(" ").field)
        #expect(paper.text == word + " ")
        #expect(session.mode == .english)
    }
}

@Test func confirmedLanguageChangesInRealTime() {
    let session = Session(lexicon: lexicon, mode: .korean)
    var paper = Paper()
    for key in "hello" { paper.apply(session.input(key).field) }
    #expect(paper.text == "hello")
    #expect(session.mode == .english)
    paper.apply(session.input(" ").field)
    #expect(session.mode == .english)
    for key in SebeolKeys.keys(for: "한글")! {
        paper.apply(session.input(key).field)
    }
    // Neither conversion waits for a space.
    #expect(paper.text == "hello 한글")
    #expect(session.mode == .korean)
    paper.apply(session.input("B").field)
    #expect(paper.text == "hello 한글!")
    #expect(paper.text == session.document)
}

@Test func mixedWordsStillConvertInEitherMode() {
    for mode in [Language.korean, .english] {
        for (keys, expected) in [("deploymr2hgsuc", "deploy했는데"), ("AIyv", "AI로"), ("ktxhgs", "ktx는")] {
            let session = Session(lexicon: lexicon, mode: mode)
            var paper = Paper()
            for key in keys { paper.apply(session.input(key).field) }
            #expect(session.document == expected, "\(session.debugLine)")
            #expect(paper.text == expected)
            #expect(session.mode == .korean)
        }
    }
}

@Test func shiftedKeysFollowConfirmedMode() {
    for automatic in [true, false] {
        for (key, hangul) in [("M", "1"), (">", "3"), ("<", "2"), ("B", "!"), ("P", ">"), ("G", "/")] {
            let korean = Session(lexicon: lexicon, autoSwitch: automatic, mode: .korean)
            #expect(korean.type(key) == hangul)
            #expect(korean.mode == .korean)
            let english = Session(lexicon: lexicon, autoSwitch: automatic, mode: .english)
            #expect(english.type(key) == key)
            #expect(english.mode == .english)
        }
    }
    let session = Session(lexicon: lexicon, mode: .english)
    #expect(session.type("of>") == "of>")
    #expect(session.mode == .english)
    #expect(session.forceMode(.korean).mode == .korean)
    #expect(session.type("M") == "of>1")

    let english = Session(lexicon: lexicon, mode: .english)
    #expect(english.type("hello!") == "hello!")
    #expect(english.mode == .english)
}

@Test func agentsStayEnglish() {
    assertTypes("agents", "agents")
    assertTypes("agents ", "agents ")
    assertCodeTokens([
        "agents.md",
        "https://agents.md",
        "README.md",
        "build.sh",
        "package.json",
        "foo.com",
        "a.b.c",
        "user@host.com",
        "src/main.swift",
        "localhost:8080",
        "https://example.com/a/b",
        "foo-bar.txt",
        "my_file.txt",
        "v2.0.1",
        "c++",
    ])
    // A Hangul word still ends at a period, and the next word can be Korean.
    let gana = (SebeolKeys.keys(for: "가") ?? "") + "." + (SebeolKeys.keys(for: "나") ?? "")
    assertTypes(gana, "가.나")
    // ㅗ on the slash key is still a vowel, not a path separator.
    assertTypes("k/f", "과")
    assertTypes("kvf", "과")
    // A dot with no filename around it does not turn a bare syllable into Latin.
    assertTypes("md", "히")
}

@Test func koreanAfterAFileName() {
    let session = Session(lexicon: lexicon, mode: .korean)
    _ = session.type("agents.md ")
    _ = session.type(SebeolKeys.keys(for: "입력")!)
    #expect(session.document == "agents.md 입력", "\(session.debugLine)")
}

@Test func koreanParticlesAfterFileNames() throws {
    for filename in ["a.md", "agents.md", "README.md", "src/main.swift"] {
        for particle in ["를", "는", "에서"] {
            let tail = try #require(SebeolKeys.keys(for: particle))
            for boundary in ["", " ", ".", "\n"] {
                let keys = filename + tail + boundary
                let expected = filename + particle + boundary
                let session = Session(lexicon: lexicon, mode: .korean)
                #expect(session.type(keys) == expected)
                #expect(clientFailures(keys, expected, mode: .korean).isEmpty)
            }
        }
    }
}

@Test func englishSentenceThenKorean() {
    let session = Session(lexicon: lexicon, mode: .korean)
    _ = session.type("hello.jfsheamfncj4")
    #expect(session.document == "hello.안녕하세요", "\(session.debugLine)")
}

@Test func commonEnglishWordsDoNotFlipMidWord() {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources")
    let dictionary = loadWordList(root.appendingPathComponent("english-words.txt"))
    let extra = loadWordList(root.appendingPathComponent("english-extra.txt"))
    var words: [String] = []
    var seen: Set<String> = []
    func add(_ word: String) {
        let key = word.lowercased()
        guard key.count >= 3, key.allSatisfy(\.isLetter), seen.insert(key).inserted else { return }
        words.append(key)
    }
    for word in extra { add(word) }
    for word in dictionary where (3...6).contains(word.count) { add(word) }
    for word in dictionary where (7...14).contains(word.count) && englishWordHidesHangulSyllable(word) {
        add(word)
    }
    var failures: [String] = []
    for word in words {
        let session = Session(lexicon: lexicon, mode: .korean)
        var typed = ""
        var latin = false
        var failed = false
        for character in word {
            typed.append(character)
            _ = session.input(character)
            if sticksAsKorean(typed) {
                let korean = Composer.compose(typed.map { Layout390.atom(for: $0) }).text
                if session.document != korean {
                    failures.append("\(word) [\(typed)] 한글 \(session.document) / \(korean)")
                    failed = true
                    break
                }
                latin = false
                continue
            }
            let plausible = lexicon.isEnglishWord(typed) || lexicon.isEnglishPrefix(typed)
            if session.document == typed {
                latin = true
            } else if latin && plausible {
                failures.append("\(word) [\(typed)] → \(session.document)")
                failed = true
                break
            }
        }
        if !failed, session.document != word {
            let korean = Composer.compose(word.map { Layout390.atom(for: $0) }).text
            if session.document != korean {
                failures.append("끝 \(word) → \(session.document)")
            }
        }
    }
    let report = failures.prefix(40).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func commonKoreanWordsStayKoreanThroughEveryKey() {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/korean-words.txt")
    let words = (try! String(contentsOf: root, encoding: .utf8))
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0.allSatisfy(isModernSyllable) && $0.count >= 2 }
    var failures: [String] = []
    for word in words {
        guard let keys = SebeolKeys.keys(for: word) else {
            failures.append("칠 수 없음 \(word)")
            continue
        }
        let session = Session(lexicon: lexicon, mode: .korean)
        var typed = ""
        for character in keys {
            typed.append(character)
            _ = session.input(character)
            let korean = Composer.compose(typed.map { Layout390.atom(for: $0) }).text
            if session.document != korean {
                failures.append("\(word) [\(typed)] → \(session.document) / \(korean)")
                break
            }
        }
    }
    let report = failures.prefix(40).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func koreanSentencesStayKorean() {
    assertTypes("jfsheamfncj4", "안녕하세요")
    assertTypes("mfskgw", "한글")
    assertTypes("nc;twndx", "세벌식")
    assertTypes("mr2ng3hduf", "했습니다")
    assertTypes("mr2hgsuc", "했는데")
    assertTypes("mrnt", "해서")
}

@Test func loneJamoDoesNotReplaceEnglish() {
    // x and a are jongseong. They must stay letters, including after a Korean word.
    assertTypes("x ifs", "x 만")
    assertTypes("a ifs", "a 만")
    assertTypes("x ", "x ")
    assertTypes("a ", "a ")
    assertTypes("i ", "i ")
    assertTypes("k ", "k ")
    assertTypes("v2", "v2")
    let session = Session(lexicon: lexicon, mode: .korean)
    _ = session.input("k")
    #expect(session.preedit == "ㄱ")
    _ = session.input("f")
    #expect(session.preedit == "가")
    _ = session.input(" ")
    #expect(session.document == "가 ")
    let ex = session.input("x")
    #expect(ex.field == .insert("x"))
    #expect(session.preedit.isEmpty, "\(session.debugLine)")
    #expect(session.document == "가 x")
}

@Test func englishWordsStayEnglish() {
    assertTypes("deploy", "deploy")
    assertTypes("hello", "hello")
    assertTypes("other", "other")
    assertTypes("the", "the")
    assertTypes("to", "to")
    assertTypes("git", "git")
    assertTypes("push", "push")
    assertTypes("and", "and")
}

@Test func mixedWordsAndCodeTokens() {
    assertTypes("deploymr2hgsuc", "deploy했는데")
    assertTypes("AIyv", "AI로")
    assertTypes("build.sh", "build.sh")
    assertTypes("v2", "v2")
    assertTypes("git push", "git push")
    assertTypes("http", "http")
    assertTypes("don't", "don't")
}

@Test func undoRestoresReadingBeforeConversion() {
    let session = Session(lexicon: lexicon, mode: .korean)
    _ = session.input("d")
    _ = session.input("e")
    #expect(session.document == "de")
    _ = session.toggle()
    #expect(session.preedit == "ㅣㅕ")
    _ = session.input("p")
    #expect(!session.document.contains("dep"), "\(session.debugLine)")
    #expect(session.mode == .korean)
}

@Test func toggleFlipsCurrentWordWhenNothingWasConverted() {
    let session = Session(lexicon: lexicon, mode: .korean)
    _ = session.input("k")
    _ = session.input("f")
    #expect(session.preedit == "가")
    _ = session.toggle()
    #expect(session.preedit.isEmpty)
    #expect(session.document == "kf")
    #expect(session.mode == .english)
}

@Test func manualModeDoesNotConvert() {
    let session = Session(lexicon: lexicon, autoSwitch: false, mode: .korean)
    _ = session.type("hello")
    #expect(session.preedit != "hello")
    _ = session.commitDisplayed()
    _ = session.forceMode(.english)
    _ = session.type("hello")
    #expect(session.preedit.isEmpty)
    #expect(session.document.hasSuffix("hello"))
}

@Test func backspaceRemovesLastJamo() {
    let session = Session(lexicon: lexicon, mode: .korean)
    _ = session.input("k")
    _ = session.input("f")
    #expect(session.preedit == "가")
    _ = session.backspace()
    #expect(session.preedit == "ㄱ")
    _ = session.backspace()
    #expect(session.preedit == "")
}

@Test func englishIsInsertedAndNavigationDoesNotRewriteIt() {
    let session = Session(lexicon: lexicon, mode: .korean)
    var paper = Paper()
    let typed = session.input("x")
    paper.apply(typed.field)
    #expect(typed.field == .insert("x"))
    #expect(session.preedit.isEmpty)
    #expect(paper.text == "x")
    #expect(paper.marked.isEmpty)

    let before = session.document
    let down = session.commitDisplayed()
    paper.apply(down.field)
    #expect(down.field.preservesCharacters)
    #expect(down.field == .none)
    #expect(session.document == before)
    #expect(paper.text == before)

    let english = Session(lexicon: lexicon, autoSwitch: false, mode: .english)
    var englishPaper = Paper()
    for character in "hello" {
        let update = english.input(character)
        englishPaper.apply(update.field)
        #expect(english.preedit.isEmpty, "\(english.debugLine)")
        #expect(update.field == .insert(String(character)))
        #expect(englishPaper.marked.isEmpty)
    }
    #expect(english.document == "hello")
    let tab = english.commitDisplayed()
    #expect(tab.field == .none)
    #expect(english.document == "hello")

    let deploy = Session(lexicon: lexicon, mode: .korean)
    var deployPaper = Paper()
    for character in "deploy" {
        let update = deploy.input(character)
        deployPaper.apply(update.field)
        #expect(deploy.preedit.isEmpty, "\(deploy.debugLine)")
        #expect(deployPaper.marked.isEmpty)
    }
    #expect(deploy.document == "deploy")
    let arrow = deploy.commitDisplayed()
    #expect(arrow.field == .none)
    #expect(deploy.document == "deploy")

    let letter = Session(lexicon: lexicon, mode: .english)
    let eye = letter.input("I")
    #expect(eye.field == .insert("I"))
    #expect(letter.preedit.isEmpty)
    let escaped = letter.commitDisplayed()
    #expect(escaped.field == .none)
    #expect(letter.document == "I")
}

@Test func navigationLeavesHangulCharactersInPlace() {
    let session = Session(lexicon: lexicon, mode: .korean)
    var paper = Paper()
    paper.apply(session.input("k").field)
    paper.apply(session.input("f").field)
    #expect(session.preedit == "가")
    #expect(paper.text == "가")
    #expect(paper.marked == "가")
    let arrow = session.commitDisplayed()
    paper.apply(arrow.field)
    #expect(arrow.field == .unmark("가"))
    #expect(arrow.field.preservesCharacters)
    #expect(session.document == "가")
    #expect(session.preedit.isEmpty)
    #expect(paper.text == "가")
    #expect(paper.marked.isEmpty)
}

/// What TextEdit actually kept on screen. `insertText` counted from
/// `selectedRange` does not cover syllables already committed before the
/// live mark, so the whole word is appended again. A Backspace the session
/// does not consume deletes one unit and commits whatever mark remains.
private struct FieldClient {
    var committed = ""
    var marked = ""
    var text: String { committed + marked }

    mutating func apply(_ field: FieldEdit) {
        switch field {
        case .none:
            break
        case .unmark(let string):
            committed += string
            marked = ""
        case .insert(let string):
            committed += string
            marked = ""
        case .mark(let string):
            marked = string
        case .replaceBeforeCaret(let utf16, let string):
            if marked.isEmpty {
                committed = dropEnd(committed, utf16)
            }
            marked = string
        case .insertThenMark(let insert, let mark):
            committed += marked + insert
            marked = mark
        case .insertReplacing(let utf16, let string):
            if marked.isEmpty {
                committed = dropEnd(committed, utf16) + string
            } else {
                marked = ""
                committed += string
            }
        case .insertReplacingThenMark(let utf16, let insert, let mark):
            if marked.isEmpty {
                committed = dropEnd(committed, utf16) + insert
            } else {
                committed += insert
            }
            marked = mark
        case .clearMarkThenInsert(let utf16, let string):
            if marked.isEmpty {
                committed = dropEnd(committed, utf16) + string
            } else {
                committed += string
            }
            marked = ""
        case .clearMarkThenMark(let utf16, let string):
            if marked.isEmpty {
                committed = dropEnd(committed, utf16)
            }
            marked = string
        case .rewrite(let utf16, let string, let thenMark):
            if marked.isEmpty {
                committed = dropEnd(committed, utf16) + string
            } else {
                committed += string
            }
            marked = thenMark
        }
    }

    /// The app handled Backspace. A leftover mark is committed, which is how
    /// the next composition is inserted beside 비 and produces 비비교.
    mutating func deleteOne() {
        if !marked.isEmpty {
            marked = dropEnd(marked, 1)
            committed += marked
            marked = ""
        } else {
            committed = dropEnd(committed, 1)
        }
    }
}

@Test func typingDoesNotReinsertCommittedSyllables() {
    let sentence = "지금 프로에서 테스트하는데 상태가 더 안좋은데?"
    let words = ["지금", "프로에서", "테스트하는데", "상태가", "더", "안좋은데"]
    let keys = words.map { SebeolKeys.keys(for: $0)! }.joined(separator: " ") + "?"
    let session = Session(lexicon: lexicon, mode: .korean)
    var client = FieldClient()
    var trace: [String] = []
    for character in keys {
        let update = session.input(character)
        client.apply(update.field)
        trace.append("\(character) \(update.field) screen=\(client.text) doc=\(session.document) mark=\(client.marked)")
        #expect(client.text == session.document, "\(trace.suffix(4).joined(separator: "\n"))")
        #expect(client.marked == session.preedit)
    }
    let duplicated = "지금 프프로프로에서 테테스테스트테스트하테스트하는데 상상태가 더 안안좋안좋은데?"
    #expect(client.text == sentence, "\(trace.suffix(6).joined(separator: "\n"))")
    #expect(client.text != duplicated)
    #expect(client.marked.isEmpty)
}

@Test func backspaceRetypeMatchesCommittedAndMarkedText() {
    let bigyo = SebeolKeys.keys(for: "비교")!
    let spaceWord = SebeolKeys.keys(for: "백스페이스")!
    fieldClientEquals(bigyo, backspaces: 1, retype: String(bigyo.suffix(1)), expect: "비교")
    fieldClientEquals(bigyo, backspaces: 2, retype: String(bigyo.suffix(2)), expect: "비교")
    fieldClientEquals(bigyo + " ", backspaces: 1, retype: " ", expect: "비교 ")
    fieldClientEquals(bigyo + " ", backspaces: 2, retype: String(bigyo.suffix(2)) + " ", expect: "비교 ")
    fieldClientEquals(spaceWord, backspaces: 2, retype: String(spaceWord.suffix(2)), expect: "백스페이스")
    fieldClientEquals(spaceWord + " ", backspaces: 2, retype: String(spaceWord.suffix(2)) + " ", expect: "백스페이스 ")
    fieldClientEquals("hello", backspaces: 3, retype: "llo", expect: "hello")
    fieldClientEquals(bigyo, backspaces: bigyo.count, retype: "hello", expect: "hello")

    let of = Session(lexicon: lexicon, mode: .korean)
    var client = FieldClient()
    for character in "one of " {
        client.apply(of.input(character).field)
    }
    #expect(client.text == "one of ")
    client.apply(of.toggle().field)
    #expect(client.text == "one 차", "Shift+Space \(client.text) doc=\(of.document)")
    #expect(client.text == of.document)
    client.apply(of.input(" ").field)
    #expect(client.text == "one 차 ")

    let typo = (SebeolKeys.keys(for: "한글") ?? "").replacing("g", with: "b")
    let undone = Session(lexicon: lexicon, mode: .korean)
    client = FieldClient()
    for character in typo + " " {
        client.apply(undone.input(character).field)
    }
    #expect(client.text == "한글 ")
    client.apply(undone.toggle().field)
    #expect(client.text == "한굴")
    #expect(client.text == undone.document)
    client.apply(undone.input(" ").field)
    #expect(client.text == "한굴 ")
}

private func fieldClientEquals(_ keys: String, backspaces: Int, retype: String, expect: String) {
    let session = Session(lexicon: lexicon, mode: .korean)
    var client = FieldClient()
    var trace: [String] = []
    func note(_ step: String) {
        trace.append("\(step) screen=\(client.text) doc=\(session.document) mark=\(client.marked) pre=\(session.preedit)")
    }
    for character in keys {
        client.apply(session.input(character).field)
        note(String(character))
        #expect(client.text == session.document, "\(trace.suffix(6).joined(separator: "\n"))")
        #expect(client.marked == session.preedit)
    }
    for _ in 0..<backspaces {
        let update = session.backspace()
        if update.field == .none {
            client.deleteOne()
        } else {
            client.apply(update.field)
        }
        note("bs \(update.field)")
        #expect(client.text == session.document, "\(trace.suffix(6).joined(separator: "\n"))")
        #expect(client.marked == session.preedit)
    }
    for character in retype {
        client.apply(session.input(character).field)
        note(String(character))
        #expect(client.text == session.document, "\(trace.suffix(6).joined(separator: "\n"))")
        #expect(client.marked == session.preedit)
    }
    let report = trace.suffix(8).joined(separator: "\n")
    #expect(client.text == expect, "\(report)")
    #expect(!client.text.contains("비비교") && !client.text.contains("백스페이백스페이스"), "\(report)")
}

@Test func backspaceRetypeDoesNotDuplicate() {
    let bigyo = SebeolKeys.keys(for: "비교")!
    let spaceWord = SebeolKeys.keys(for: "백스페이스")!
    fieldEqualsDocument(bigyo, backspaces: 1, retype: String(bigyo.suffix(1)), expect: "비교")
    fieldEqualsDocument(bigyo, backspaces: 2, retype: String(bigyo.suffix(2)), expect: "비교")
    fieldEqualsDocument(bigyo + " ", backspaces: 1, retype: " ", expect: "비교 ")
    fieldEqualsDocument(bigyo + " ", backspaces: 2, retype: String(bigyo.suffix(2)) + " ", expect: "비교 ")
    fieldEqualsDocument(spaceWord, backspaces: 2, retype: String(spaceWord.suffix(2)), expect: "백스페이스")
    fieldEqualsDocument(spaceWord + " ", backspaces: 2, retype: String(spaceWord.suffix(2)) + " ", expect: "백스페이스 ")
    fieldEqualsDocument("hello", backspaces: 3, retype: "llo", expect: "hello")
    fieldEqualsDocument(bigyo, backspaces: bigyo.count, retype: "hello", expect: "hello")

    let typo = (SebeolKeys.keys(for: "한글") ?? "").replacing("g", with: "b")
    fieldEqualsDocument(typo + " ", backspaces: 0, retype: "", expect: "한글 ")
    let undone = Session(lexicon: lexicon, mode: .korean)
    var paper = Paper()
    drive(&paper, undone, typo + " ")
    #expect(paper.text == "한글 ")
    let restored = undone.toggle()
    if restored.field == .none {
        paper.deleteOne()
    } else {
        paper.apply(restored.field)
    }
    #expect(paper.text == "한굴")
    #expect(paper.text == undone.document)
    drive(&paper, undone, " ")
    #expect(paper.text == "한굴 ")
    #expect(paper.text == undone.document)
}

private func fieldEqualsDocument(_ keys: String, backspaces: Int, retype: String, expect: String) {
    let session = Session(lexicon: lexicon, mode: .korean)
    var paper = Paper()
    var trace: [String] = []
    func note(_ step: String) {
        trace.append("\(step) paper=\(paper.text) doc=\(session.document) mark=\(paper.marked) pre=\(session.preedit)")
    }
    for character in keys {
        drive(&paper, session, String(character))
        note("\(character)")
    }
    for _ in 0..<backspaces {
        let update = session.backspace()
        if update.field == .none {
            paper.deleteOne()
        } else {
            paper.apply(update.field)
        }
        note("bs \(update.field)")
    }
    drive(&paper, session, retype)
    note("retype")
    let report = trace.suffix(8).joined(separator: "\n")
    #expect(paper.text == session.document, "\(report)")
    #expect(paper.marked == session.preedit, "\(report)")
    #expect(paper.text == expect, "\(report)")
}

private func drive(_ paper: inout Paper, _ session: Session, _ keys: String) {
    for character in keys {
        paper.apply(session.input(character).field)
    }
}

@Test func backspaceOfCommittedEnglishPassesThrough() {
    let session = Session(lexicon: lexicon, mode: .korean)
    var paper = Paper()
    paper.apply(session.input("x").field)
    let deleted = session.backspace()
    #expect(deleted.field == .none)
    paper.deleteOne()
    #expect(session.document.isEmpty)
    #expect(paper.text.isEmpty)

    paper.apply(session.input("v").field)
    paper.apply(session.input("2").field)
    #expect(session.preedit.isEmpty)
    #expect(session.document == "v2")
    #expect(paper.text == "v2")
    #expect(paper.marked.isEmpty)
}

@Test func repeatedBareJamoStaysKorean() {
    let jinjja = SebeolKeys.keys(for: "진짜")!
    let joha = SebeolKeys.keys(for: "좋아")!
    let samples = [
        "mm": "ㅎㅎ",
        "mmm": "ㅎㅎㅎ",
        "00": "ㅋㅋ",
        "0000": "ㅋㅋㅋㅋ",
        "55": "ㅠㅠ",
        "99": "ㅜㅜ",
        "bb": "ㅜㅜ",
        "uu": "ㄸ",
        "jj": "ㅇㅇ",
        "kn": "ㄱㅅ",
        ";;": "ㅃ",
        "j0": "ㅇㅋ",
        "kk": "ㄲ",
        "ll": "ㅉ",
        "nn": "ㅆ",
        "000 \(jinjja)": "ㅋㅋㅋ 진짜",
        "\(joha)mm": "좋아ㅎㅎ",
    ]
    var failures: [String] = []
    for (keys, expected) in samples {
        let session = Session(lexicon: lexicon, mode: .korean)
        var paper = Paper()
        var typed = ""
        for character in keys {
            typed.append(character)
            let update = session.input(character)
            paper.apply(update.field)
            if paper.text != expected.prefix(paper.text.count) && paper.text != session.document {
                failures.append("\(keys) [\(typed)] paper=\(paper.text) doc=\(session.document) \(session.debugLine) \(update.field)")
                break
            }
            if paper.text != session.document || paper.marked != session.preedit {
                failures.append("어긋남 \(keys) [\(typed)] paper=\(paper.text) mark=\(paper.marked) doc=\(session.document) pre=\(session.preedit) \(update.field)")
                break
            }
        }
        if paper.text != expected || session.document != expected {
            failures.append("끝 \(keys) paper=\(paper.text) doc=\(session.document) \(session.debugLine) /\(expected)")
        }
    }
    for (keys, expected) in ["mm ": "ㅎㅎ ", "00 ": "ㅋㅋ ", "55 ": "ㅠㅠ ", "kn ": "ㄱㅅ "] {
        let session = Session(lexicon: lexicon, mode: .korean)
        var paper = Paper()
        for character in keys {
            let update = session.input(character)
            if update.field.sendsMoreThanOneEdit {
                failures.append("두 번 씀 \(keys) \(update.field)")
            }
            paper.apply(update.field)
        }
        if paper.text != expected || session.document != expected {
            failures.append("끝 \(keys) paper=\(paper.text) doc=\(session.document) /\(expected)")
        }
    }
    let report = failures.prefix(20).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func capitalizedEnglishReplacesLeadingShift() {
    let words = ["Introduce", "Hello", "Please", "Kubernetes", "Open", "Yes", "My", "To", "TV"]
    var failures: [String] = []
    for word in words {
        let session = Session(lexicon: lexicon, mode: .korean)
        var paper = Paper()
        var typed = ""
        for character in word {
            typed.append(character)
            let update = session.input(character)
            if update.field.sendsMoreThanOneEdit {
                failures.append("두 번 씀 \(word) [\(typed)] \(update.field)")
                break
            }
            paper.apply(update.field)
            if paper.text != session.document || paper.marked != session.preedit {
                failures.append("어긋남 \(word) [\(typed)] paper=\(paper.text) doc=\(session.document) \(update.field)")
                break
            }
            if typed.count >= 2, paper.text != typed {
                failures.append("\(word) [\(typed)] paper=\(paper.text) doc=\(session.document) \(session.debugLine)")
                break
            }
        }
        if paper.text != word || session.preedit.isEmpty == false {
            failures.append("끝 \(word) paper=\(paper.text) pre=\(session.preedit)")
        }
    }
    let report = failures.prefix(12).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func shiftedSeparatorsStayDigits() {
    let korean = [
        "N.M": "0.1",
        ">.MJ": "3.14",
        "M,NNN": "1,000",
        "<N<L.MN.<>": "2026.10.23",
        "MN": "10",
        "Mkr": "1개",
        "MN%": "10%",
        "OK": "95",
        "IO": "89",
        "agents.md": "agents.md",
        "x.com": "x.com",
        "file.txt": "file.txt",
    ]
    var failures: [String] = []
    for (keys, expected) in korean {
        failures += clientFailures(keys, expected, mode: .korean)
    }
    failures += clientFailures("N.M", "N.M", mode: .english)
    failures += clientFailures(">.MJ", ">.MJ", mode: .english)
    failures += clientFailures("MN", "MN", mode: .english)
    failures += clientFailures("OK", "OK", mode: .english)
    failures += clientFailures("agents.md", "agents.md", mode: .english)
    failures += clientFailures("x.com", "x.com", mode: .english)
    let report = failures.prefix(16).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

private func clientFailures(_ keys: String, _ expected: String, mode: Language) -> [String] {
    let session = Session(lexicon: lexicon, mode: mode)
    var paper = Paper()
    var typed = ""
    var failures: [String] = []
    for character in keys {
        typed.append(character)
        let update = session.input(character)
        if update.field.sendsMoreThanOneEdit {
            failures.append("두 번 씀 \(keys) [\(typed)] \(update.field)")
            return failures
        }
        paper.apply(update.field)
        if paper.text != session.document || paper.marked != session.preedit {
            failures.append("어긋남 \(keys) [\(typed)] paper=\(paper.text) doc=\(session.document) \(update.field)")
            return failures
        }
    }
    if paper.text != expected || session.document != expected {
        failures.append("\(mode) \(keys) paper=\(paper.text) doc=\(session.document) \(session.debugLine) /\(expected)")
    }
    return failures
}

@Test func batchimOnDigitKeysStaysKorean() {
    let words = ["했어", "있어", "했다", "갔어", "없어", "있는", "했습니다", "했는데"]
    var failures: [String] = []
    for word in words {
        guard let keys = SebeolKeys.keys(for: word) else {
            failures.append("키 없음 \(word)")
            continue
        }
        if let drift = hangulDrift(keys) {
            failures.append("\(word) \(drift)")
        }
        failures += clientFailures(keys + ".", word + ".", mode: .korean)
        failures += clientFailures(keys + " ", word + " ", mode: .korean)
        let session = Session(lexicon: lexicon, mode: .korean)
        var paper = Paper()
        for character in keys + "." {
            paper.apply(session.input(character).field)
        }
        if paper.text != word + "." || paper.text.contains(" ") {
            failures.append("마침표 \(keys). paper=\(paper.text) / \(word).")
        }
    }
    failures += clientFailures("mr2jt.", "했어.", mode: .korean)
    failures += clientFailures("mr2jt ", "했어 ", mode: .korean)
    let report = failures.prefix(20).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func doubledChoseongStaysKorean() {
    let words = [
        "까", "따", "빠", "싸", "짜", "쪽", "꼭", "똑", "뽕", "쌓",
        "쪽에서", "쪽은", "똑같이", "아까", "어까", "이까", "아가", "아는",
        "아빠", "쓰레기", "깨끗", "따뜻", "짜증", "뭔가",
    ]
    let particles = [
        "는", "은", "이", "가", "를", "을", "에", "에서", "로", "으로",
        "와", "과", "도", "만", "의", "하고", "했", "해", "하는",
    ]
    var failures: [String] = []
    for word in words {
        guard let keys = SebeolKeys.keys(for: word) else {
            failures.append("키 없음 \(word)")
            continue
        }
        if let drift = hangulDrift(keys) {
            failures.append("\(word) \(drift)")
        }
        failures += clientFailures(keys, word, mode: .korean)
        for particle in particles {
            guard let tail = SebeolKeys.keys(for: particle) else { continue }
            let combined = word + particle
            if let drift = hangulDrift(keys + tail) {
                failures.append("\(combined) \(drift)")
            }
        }
    }
    if let geurok = SebeolKeys.keys(for: "그록"), let jjok = SebeolKeys.keys(for: "쪽에서") {
        failures += clientFailures(geurok + " " + jjok, "그록 쪽에서", mode: .korean)
        if let drift = hangulDrift(jjok) {
            failures.append("쪽에서 \(drift)")
        }
    } else {
        failures.append("키 없음 그록 쪽에서")
    }
    let report = failures.prefix(20).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func acronymPlusParticle() {
    let samples: [(String, String)] = [
        ("ktx", "는"),
        ("api", "를"),
        ("url", "을"),
        ("mvp", "가"),
        ("sdk", "로"),
        ("github", "에"),
        ("html", "에서"),
        ("cpu", "로"),
    ]
    var failures: [String] = []
    for (head, particle) in samples {
        guard let tail = SebeolKeys.keys(for: particle) else {
            failures.append("키 없음 \(particle)")
            continue
        }
        failures += clientFailures(head + tail, head + particle, mode: .korean)
    }
    for word in ["나는", "가는", "하는", "했는데", "입력", "한은", "집은", "건가", "건데", "된는", "한다는", "것은", "걸로", "내가", "뭔가"] {
        guard let keys = SebeolKeys.keys(for: word) else {
            failures.append("키 없음 \(word)")
            continue
        }
        failures += clientFailures(keys, word, mode: .korean)
    }
    failures += clientFailures("ktskf", "건가", mode: .korean)
    failures += clientFailures("hello", "hello", mode: .korean)
    failures += clientFailures("other", "other", mode: .korean)
    failures += clientFailures("Introduce", "Introduce", mode: .korean)
    failures += clientFailures("agents.md", "agents.md", mode: .korean)
    failures += clientFailures("mm", "ㅎㅎ", mode: .korean)
    let report = failures.prefix(16).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func koreanWordsStayKoreanBeforeParticles() {
    let particles = [
        "는", "은", "이", "가", "를", "을", "에", "에서", "로", "으로",
        "와", "과", "도", "만", "의", "하고", "했", "해", "하는",
    ]
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/korean-words.txt")
    let words = (try! String(contentsOf: root, encoding: .utf8))
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0.allSatisfy(isModernSyllable) }
    let particleKeys = particles.compactMap { particle -> (String, String)? in
        guard let keys = SebeolKeys.keys(for: particle) else { return nil }
        return (particle, keys)
    }
    var failures: [String] = []
    for word in words {
        guard let wordKeys = SebeolKeys.keys(for: word) else { continue }
        if let drift = hangulDrift(wordKeys) {
            failures.append("\(word) \(drift)")
        }
        for (particle, tail) in particleKeys {
            if let drift = hangulDrift(wordKeys + tail) {
                failures.append("\(word)+\(particle) \(drift)")
            }
        }
    }
    let report = failures.prefix(30).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func eachKeyReachesTheClientOnce() {
    let samples = [
        "Mkr": "1개",
        ">nd": "3시",
        "MNkr": "10개",
        "<N<Lhes": "2026년",
        "x ifs": "x 만",
        "deploymr2hgsuc": "deploy했는데",
        "AIyv": "AI로",
        "MN%": "10%",
        ">.MJ": "3.14",
        "jd3yex": "입력",
        "agents.md": "agents.md",
        "hello": "hello",
        "v2": "v2",
    ]
    var failures: [String] = []
    for (keys, expected) in samples {
        let session = Session(lexicon: lexicon, mode: .korean)
        var paper = Paper()
        var typed = ""
        for character in keys {
            typed.append(character)
            let update = session.input(character)
            if update.field.sendsMoreThanOneEdit {
                failures.append("두 번 씀 \(keys) [\(typed)] \(update.field)")
                break
            }
            paper.apply(update.field)
            if paper.text != session.document || paper.marked != session.preedit {
                failures.append("\(keys) [\(typed)] paper=\(paper.text) mark=\(paper.marked) doc=\(session.document) pre=\(session.preedit) \(update.field)")
                break
            }
        }
        if paper.text != expected || session.document != expected {
            failures.append("끝 \(keys) paper=\(paper.text) doc=\(session.document) /\(expected)")
        }
        let stopped = session.commitDisplayed()
        paper.apply(stopped.field)
        if !stopped.field.preservesCharacters || paper.text != expected {
            failures.append("멈춤 \(keys) paper=\(paper.text) \(stopped.field)")
        }
        if paper.text != session.document {
            failures.append("멈춤 불일치 \(keys) paper=\(paper.text) doc=\(session.document)")
        }
    }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/korean-words.txt")
    let words = (try! String(contentsOf: root, encoding: .utf8))
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0.allSatisfy(isModernSyllable) && $0.count >= 2 }
    for word in words {
        guard let keys = SebeolKeys.keys(for: word) else { continue }
        let session = Session(lexicon: lexicon, mode: .korean)
        var paper = Paper()
        for character in keys {
            let update = session.input(character)
            if update.field.sendsMoreThanOneEdit {
                failures.append("두 번 씀 \(word) \(update.field)")
                break
            }
            paper.apply(update.field)
            if paper.text != session.document {
                failures.append("\(word) paper=\(paper.text) doc=\(session.document) \(update.field)")
                break
            }
        }
        if session.document != word || paper.text != word {
            failures.append("끝 \(word) paper=\(paper.text) doc=\(session.document)")
        }
    }
    let report = failures.prefix(20).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func fieldEditsMatchTheDocument() {
    let samples = [
        "x ifs",
        "a ifs",
        "x ",
        "k ",
        "i ",
        "v2",
        "jd3yex",
        "deploymr2hgsuc",
        "AIyv",
        "agents.md",
        "https://agents.md",
        "build.sh",
        "MN",
        "<N<L",
        "hello",
        "other",
        "git push",
        "don't",
        "MNkr",
        "k/f",
        "kvf",
    ]
    var failures: [String] = []
    for sample in samples {
        let session = Session(lexicon: lexicon, mode: .korean)
        var paper = Paper()
        var typed = ""
        for character in sample {
            typed.append(character)
            let update = session.input(character)
            paper.apply(update.field)
            if paper.text != session.document || paper.marked != session.preedit {
                failures.append("\(sample) [\(typed)] paper=\(paper.text) mark=\(paper.marked) doc=\(session.document) pre=\(session.preedit) \(update.field)")
                break
            }
        }
        let stopped = session.commitDisplayed()
        paper.apply(stopped.field)
        if stopped.field.preservesCharacters == false || paper.text != session.document {
            failures.append("멈춤 \(sample) \(stopped.field) paper=\(paper.text) doc=\(session.document)")
        }
        if session.preedit.isEmpty == false || paper.marked.isEmpty == false {
            failures.append("조합 남음 \(sample) \(session.preedit)")
        }
    }
    let english = Session(lexicon: lexicon, mode: .english)
    var paper = Paper()
    for character in "TV API MN" {
        let update = english.input(character)
        paper.apply(update.field)
        if paper.marked.isEmpty == false || paper.text != english.document {
            failures.append("영문 \(paper.text) \(english.document)")
            break
        }
    }
    let report = failures.prefix(20).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func shortcutsAndSecureInputPassThrough() {
    #expect(InputGate.shouldPassThrough(secureInput: true, command: false, control: false, option: false))
    #expect(InputGate.shouldPassThrough(secureInput: false, command: true, control: false, option: false))
    #expect(InputGate.shouldPassThrough(secureInput: false, command: false, control: true, option: false))
    #expect(InputGate.shouldPassThrough(secureInput: false, command: false, control: false, option: true))
    #expect(!InputGate.shouldPassThrough(secureInput: false, command: false, control: false, option: false))
}

private func assertCodeTokens(_ samples: [String]) {
    var failures: [String] = []
    let joiners: Set<Character> = [".", ":", "/", "@", "_", "-", "+", "?", "=", "&", "%", "#"]
    for sample in samples {
        let session = Session(lexicon: lexicon, mode: .korean)
        var typed = ""
        var sawJoiner = false
        for character in sample {
            typed.append(character)
            _ = session.input(character)
            if joiners.contains(character) { sawJoiner = true }
            if sawJoiner, session.document != typed {
                failures.append("\(sample) [\(typed)] → \(session.document)")
                break
            }
        }
        if !failures.contains(where: { $0.hasPrefix(sample) }), session.document != sample {
            failures.append("\(sample) → \(session.document)")
        }
    }
    let report = failures.prefix(40).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

private func loadWordList(_ url: URL) -> [String] {
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return text.split(whereSeparator: \.isNewline).map {
        String($0).trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// "age" + "nts": a real English stem whose next three keys are one syllable.
private func englishWordHidesHangulSyllable(_ word: String) -> Bool {
    let chars = Array(word)
    guard chars.count >= 6 else { return false }
    for start in 3..<(chars.count - 2) {
        let stem = String(chars[..<start])
        guard lexicon.isEnglishWord(stem) else { continue }
        let tail = String(chars[start..<start + 3])
        if cleanSyllables(tail) == 1 { return true }
    }
    return false
}

private func cleanSyllables(_ text: String) -> Int {
    let pieces = Composer.compose(text.map { Layout390.atom(for: $0) }).pieces
    guard !pieces.isEmpty, pieces.allSatisfy({ $0 == .syllable }) else { return 0 }
    return pieces.count
}

private func sticksAsKorean(_ text: String) -> Bool {
    let pieces = Composer.compose(text.map { Layout390.atom(for: $0) }).pieces
    guard !pieces.isEmpty else { return false }
    var body = pieces
    if body.last == .bareChoseong { body.removeLast() }
    guard body.contains(.syllable) else { return false }
    return body.allSatisfy { $0 == .syllable || $0 == .digit }
}

@Test func arrowsAfterDashAndEquals() {
    let dash = Session(lexicon: lexicon, mode: .korean)
    var paper = Paper()
    paper.apply(dash.input("-").field)
    paper.apply(dash.input(">").field)
    #expect(paper.text == "->")
    #expect(dash.document == "->")
    paper.apply(dash.toggle().field)
    #expect(paper.text == "-3")
    #expect(dash.document == "-3")
    paper.apply(dash.input(" ").field)
    #expect(paper.text == "-3 ")
    #expect(dash.document == "-3 ")

    let equals = Session(lexicon: lexicon, mode: .korean)
    var equalsPaper = Paper()
    equalsPaper.apply(equals.input("=").field)
    equalsPaper.apply(equals.input(">").field)
    #expect(equalsPaper.text == "=>")
    equalsPaper.apply(equals.toggle().field)
    #expect(equalsPaper.text == "=3")
    #expect(equals.document == "=3")

    #expect(Session(lexicon: lexicon, mode: .korean).type(">") == "3")
    #expect(Session(lexicon: lexicon, mode: .korean).type("<") == "2")
    #expect(Session(lexicon: lexicon, mode: .korean).type("-<") == "-2")
    #expect(Session(lexicon: lexicon, mode: .korean).type("Y-") == "<-")
    #expect(Session(lexicon: lexicon, mode: .korean).type("-->") == "-->")
    #expect(Session(lexicon: lexicon, mode: .korean).type(">.MJ") == "3.14")
    #expect(Session(lexicon: lexicon, mode: .english).type("=>") == "=>")

    let hangul = (SebeolKeys.keys(for: "한글") ?? "") + "->"
    #expect(Session(lexicon: lexicon, mode: .korean).type(hangul) == "한글->")

    let consumed = Session(lexicon: lexicon, mode: .korean)
    _ = consumed.type("->")
    _ = consumed.input(" ")
    _ = consumed.toggle()
    #expect(consumed.document == "-> ")
}

@Test func padDigitsStayDigitsInKoreanMode() {
    let pad = ["M": "1", "N": "0", "U": "7", "I": "8", "O": "9", "J": "4", "K": "5", "L": "6", "<": "2", ">": "3"]
    var failures: [String] = []
    for (key, digit) in pad {
        let session = Session(lexicon: lexicon, mode: .korean)
        _ = session.input(key.first!)
        if session.document != digit {
            failures.append("\(key) → \(session.document)")
        }
    }
    for (left, leftDigit) in pad {
        for (right, rightDigit) in pad {
            let keys = left + right
            let session = Session(lexicon: lexicon, mode: .korean)
            for character in keys {
                _ = session.input(character)
            }
            let expected = leftDigit + rightDigit
            if session.document != expected {
                failures.append("\(keys) → \(session.document) / \(expected)")
            }
        }
    }
    let samples = [
        "M": "1",
        "MN": "10",
        "MNN": "100",
        "<N<L": "2026",
        ">.MJ": "3.14",
        "MN%": "10%",
        "MNkr": "10개",
        "<N<Lhes MNjbtw <>jdw": "2026년 10월 23일",
        "IO": "89",
        "OK": "95",
        "UI": "78",
        "ML": "16",
    ]
    for (keys, expected) in samples {
        let session = Session(lexicon: lexicon, mode: .korean)
        var typed = ""
        for character in keys {
            typed.append(character)
            _ = session.input(character)
            if session.document.contains(where: \.isUppercase) {
                failures.append("대문자 \(typed) → \(session.document)")
                break
            }
        }
        if session.document != expected {
            failures.append("\(keys) → \(session.document) / \(expected)")
        }
    }
    let report = failures.prefix(40).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func englishModeKeepsAllCaps() {
    assertTypes("MN", "MN", mode: .english)
    assertTypes("API", "API", mode: .english)
    assertTypes("TV", "TV", mode: .english)
    assertTypes("OK", "OK", mode: .english)
    assertTypes("TV", "TV")
}

@Test func englishContextKeepsFunctionWords() {
    assertTypes("one of the", "one of the")
    assertTypes("kind of", "kind of")
    assertTypes("out of the", "out of the")
    assertTypes("part of", "part of")
    assertTypes("one to", "one to")
    assertTypes("one in", "one in")
    assertTypes("one is", "one is")
    let hangul = SebeolKeys.keys(for: "한글")!
    assertTypes("one " + hangul, "one 한글")

    let han = SebeolKeys.keys(for: "한")!
    assertTypes(han + " of", "한 차")
    assertTypes(han + " the", "한 the")
    assertTypes("of", "차")
    assertTypes("one. of", "one. of")
    assertTypes("one\nof", "one\nof")

    let session = Session(lexicon: lexicon, mode: .korean)
    var paper = Paper()
    for character in "one of " {
        paper.apply(session.input(character).field)
    }
    #expect(paper.text == "one of ")
    paper.apply(session.toggle().field)
    #expect(paper.text == "one 차")
    #expect(session.document == "one 차")
    paper.apply(session.input(" ").field)
    #expect(paper.text == "one 차 ")
    #expect(session.document == "one 차 ")

    _ = session.commitDisplayed(endingRun: true)
    for character in "of" {
        paper.apply(session.input(character).field)
    }
    #expect(session.document.hasSuffix("차"))
}

@Test func shiftSpaceUndoesTypoCorrection() {
    let typed = (SebeolKeys.keys(for: "한글") ?? "").replacing("g", with: "b")
    #expect(typed.contains("b"))
    let session = Session(lexicon: lexicon, mode: .korean)
    var paper = Paper()
    for character in typed + " " {
        paper.apply(session.input(character).field)
    }
    #expect(paper.text == "한글 ")
    #expect(session.document == "한글 ")
    paper.apply(session.toggle().field)
    #expect(session.document == "한굴")
    #expect(paper.text == "한굴")
    paper.apply(session.input(" ").field)
    #expect(session.document == "한굴 ")
    #expect(paper.text == "한굴 ")

    let period = Session(lexicon: lexicon, mode: .korean)
    #expect(period.type(typed + ".") == "한글.")
    _ = period.toggle()
    #expect(period.document == "한굴")
    #expect(period.type(".") == "한굴.")
}

@Test func realisticTyposAreCorrectedOnce() {
    func committed(_ keys: String) -> String {
        Session(lexicon: lexicon, mode: .korean).type(keys + " ")
    }
    let slang = SebeolKeys.keys(for: "싸람")!
    #expect(committed(slang) == "싸람 ")
    #expect(committed(SebeolKeys.keys(for: "한글")!) == "한글 ")
    #expect(committed(SebeolKeys.keys(for: "했어")!) == "했어 ")
    #expect(committed(SebeolKeys.keys(for: "갔어")!) == "갔어 ")
    #expect(committed("mm") == "ㅎㅎ ")

    let english = Session(lexicon: lexicon, autoSwitch: false, mode: .english)
    #expect(english.type("hellp ") == "hello ")
    _ = english.toggle()
    #expect(english.document == "hellp")
    #expect(english.type(" ") == "hellp ")
}

@Test func typoLogRemembersARetypeAndAOneSyllablePair() {
    let memory = MemoryTypos()
    let session = Session(lexicon: lexicon, mode: .korean, typos: memory)
    let typo = (SebeolKeys.keys(for: "한글") ?? "").replacing("g", with: "b")
    let fixed = SebeolKeys.keys(for: "한글")!
    _ = session.type(typo)
    _ = session.backspace()
    _ = session.backspace()
    _ = session.type("gw ")
    #expect(memory.rows.count == 1)
    #expect(memory.rows[0].wrong == "한굴")
    #expect(memory.rows[0].final == "한글")
    #expect(memory.rows[0].wrongKeys == typo)
    #expect(memory.rows[0].finalKeys == fixed)

    let seeded = MemoryTypos()
    let rare = SebeolKeys.keys(for: "갂")!
    seeded.rows.append((wrong: "갂", wrongKeys: rare, final: "가", finalKeys: "kf"))
    let again = Session(lexicon: lexicon, mode: .korean, typos: seeded)
    #expect(again.type(rare + " ") == "가 ")
    seeded.rows.append((wrong: "갂", wrongKeys: rare, final: "나", finalKeys: "hf"))
    let ambiguous = Session(lexicon: lexicon, mode: .korean, typos: seeded)
    #expect(ambiguous.type(rare + " ") == "갂 ")

    let real = MemoryTypos()
    let gul = SebeolKeys.keys(for: "굴")!
    real.rows.append((wrong: "굴", wrongKeys: gul, final: "가", finalKeys: "kf"))
    let oyster = Session(lexicon: lexicon, mode: .korean, typos: real)
    #expect(oyster.type(gul + " ") == "굴 ")

    let dropped = MemoryTypos()
    let secure = Session(lexicon: lexicon, mode: .korean, typos: dropped)
    _ = secure.type(typo)
    _ = secure.backspace()
    _ = secure.discard()
    #expect(dropped.rows.isEmpty)
}

@Test func dictionaryWordsAreNotAutoCorrected() {
    let particles = KoreanEndings.longestFirst
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/korean-words.txt")
    let words = (try! String(contentsOf: root, encoding: .utf8))
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0.allSatisfy(isModernSyllable) }
    var failures: [String] = []
    for word in words {
        guard let keys = SebeolKeys.keys(for: word) else { continue }
        let session = Session(lexicon: lexicon, mode: .korean)
        if session.type(keys + " ") != word + " " {
            failures.append("\(word) → \(session.document)")
        }
        if failures.count > 12 { break }
        for particle in particles {
            guard let tail = SebeolKeys.keys(for: particle) else { continue }
            let combined = Session(lexicon: lexicon, mode: .korean)
            let expected = word + particle + " "
            if combined.type(keys + tail + " ") != expected {
                failures.append("\(word)+\(particle) → \(combined.document)")
            }
            if failures.count > 12 { break }
        }
    }
    let report = failures.prefix(12).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func realKoreanWordsStayUncorrected() {
    #expect(lexicon.validKoreanWordCount > 100_000)
    #expect(lexicon.isValidKorean("바탕"))
    #expect(lexicon.isValidKorean("공간"))
    let samples = [
        "바탕", "공간", "사랑", "학교", "회사", "시간", "오늘", "내일", "컴퓨터", "키보드",
        "창문", "하늘", "바다", "친구", "가족", "아침", "저녁", "커피", "전화", "마음",
        "세상", "나라", "영화", "음악", "책상", "의자", "문장", "단어", "사전", "구름",
        "바람", "나무", "교실", "학생", "부모", "아이", "점심", "저녁", "문제", "이유",
    ]
    var failures: [String] = []
    for word in samples {
        guard let keys = SebeolKeys.keys(for: word) else {
            failures.append("no keys \(word)")
            continue
        }
        let session = Session(lexicon: lexicon, mode: .korean)
        if session.type(keys + " ") != word + " " {
            failures.append("\(word) → \(session.document)")
        }
        for particle in ["에", "의", "을", "에서"] {
            guard let tail = SebeolKeys.keys(for: particle) else { continue }
            let combined = Session(lexicon: lexicon, mode: .korean)
            let expected = word + particle + " "
            if combined.type(keys + tail + " ") != expected {
                failures.append("\(word)+\(particle) → \(combined.document)")
            }
        }
    }
    let oddKeys = (SebeolKeys.keys(for: "갂") ?? "") + (SebeolKeys.keys(for: "까") ?? "")
    let odd = Session(lexicon: lexicon, mode: .korean)
    if odd.type(oddKeys + " ") != "갂까 " {
        failures.append("갂까 → \(odd.document)")
    }
    let report = failures.prefix(12).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func validityListSampleIsNotAutoCorrected() {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/korean-valid.txt")
    let words = (try! String(contentsOf: root, encoding: .utf8))
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0.count >= 2 && $0.allSatisfy(isModernSyllable) }
    var checked = 0
    var failures: [String] = []
    for (index, word) in words.enumerated() {
        let named = word == "바탕" || word == "공간"
        guard named || index % 40 == 0 else { continue }
        guard let keys = SebeolKeys.keys(for: word) else { continue }
        let atoms = keys.map { Layout390.atom(for: $0) }
        if let fixed = TypoCorrector.correction(
            composed: word,
            keys: atoms,
            language: .korean,
            lexicon: lexicon,
            memory: nil
        ) {
            failures.append("\(word) → \(fixed)")
            if failures.count > 12 { break }
        }
        checked += 1
    }
    #expect(checked > 2000)
    let report = failures.prefix(12).joined(separator: "\n")
    #expect(failures.isEmpty, "\(failures.count) failures\n\(report)")
}

@Test func typoCorrectionCanBeTurnedOff() {
    let typed = (SebeolKeys.keys(for: "한글") ?? "").replacing("g", with: "b")
    let off = Session(lexicon: lexicon, mode: .korean)
    off.correctsTypos = false
    #expect(off.type(typed + " ") == "한굴 ")

    let memory = MemoryTypos()
    let retype = Session(lexicon: lexicon, mode: .korean, typos: memory)
    retype.correctsTypos = false
    _ = retype.type(typed)
    _ = retype.backspace()
    _ = retype.backspace()
    _ = retype.type("gw ")
    #expect(memory.rows.count == 1)
    #expect(memory.rows[0].wrong == "한굴")
    #expect(memory.rows[0].final == "한글")
    #expect(retype.document == "한글 ")

    let seeded = MemoryTypos()
    seeded.rows.append((wrong: "한굴", wrongKeys: typed, final: "한글", finalKeys: SebeolKeys.keys(for: "한글")!))
    let blocked = Session(lexicon: lexicon, mode: .korean, typos: seeded)
    blocked.correctsTypos = false
    #expect(blocked.type(typed + " ") == "한굴 ")
}

final class MemoryTypos: TypoMemory {
    var rows: [(wrong: String, wrongKeys: String, final: String, finalKeys: String)] = []

    func record(wrong: String, wrongKeys: String, final: String, finalKeys: String) {
        rows.append((wrong, wrongKeys, final, finalKeys))
    }

    func uniqueFinal(for wrong: String) -> String? {
        let matches = rows.filter { $0.wrong == wrong }.map(\.final)
        let unique = Set(matches)
        return unique.count == 1 ? matches[0] : nil
    }
}

private func assertTypes(_ keys: String, _ expected: String, mode: Language = .korean) {
    let session = Session(lexicon: lexicon, mode: mode)
    var trace: [String] = []
    for character in keys {
        _ = session.input(character)
        trace.append(session.debugLine)
    }
    #expect(session.document == expected, "\(trace.joined(separator: "\n"))")
}

/// Every prefix must stay the Hangul those keys compose. A Latin flash
/// (`ll` for ㅉ, `jfk가` for 아까) is a failure even if the last key recovers.
private func hangulDrift(_ keys: String) -> String? {
    let session = Session(lexicon: lexicon, mode: .korean)
    var typed = ""
    for character in keys {
        typed.append(character)
        _ = session.input(character)
        let hangul = Composer.compose(typed.map { Layout390.atom(for: $0) }).text
        if session.document != hangul {
            return "\(typed) → \(session.document) / \(hangul)"
        }
    }
    return nil
}

private func isModernSyllable(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
    return (0xAC00...0xD7A3).contains(scalar.value)
}

/// 390 keystrokes for a Hangul word. A letter key wins over a digit that
/// produces the same jamo, so the sweep hits the English-looking readings.
private enum SebeolKeys {
    static func keys(for word: String) -> String? {
        var result = ""
        for character in word {
            guard let part = keys(for: character) else { return nil }
            result += part
        }
        return result
    }

    static func keys(for syllable: Character) -> String? {
        guard let scalar = syllable.unicodeScalars.first else { return nil }
        let code = Int(scalar.value - 0xAC00)
        let cho = UInt32(0x1100 + code / 588)
        let jung = UInt32(0x1161 + (code % 588) / 28)
        let jongIndex = code % 28
        guard let choKeys = sequence(.choseong, cho), let jungKeys = sequence(.jungseong, jung) else { return nil }
        var text = choKeys + jungKeys
        if jongIndex != 0 {
            guard let jongKeys = sequence(.jongseong, UInt32(0x11A8 + jongIndex - 1)) else { return nil }
            text += jongKeys
        }
        return text
    }

    private static let byJamo: [Jamo: Character] = {
        let probe = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789`-=[]\\;',./~!@#$%^&*()_+{}|:\"<>?")
        var map: [Jamo: Character] = [:]
        for character in probe {
            if case .jamo(let jamo) = Layout390.atom(for: character).korean, map[jamo] == nil {
                map[jamo] = character
            }
        }
        return map
    }()

    private static func sequence(_ kind: JamoKind, _ scalar: UInt32) -> String? {
        let target = Jamo(scalar: scalar, kind: kind)
        if let key = byJamo[target] { return String(key) }
        for (first, firstKey) in byJamo where first.kind == kind {
            for (second, secondKey) in byJamo where second.kind == kind {
                if Hangul.merge(first, second) == target {
                    return String(firstKey) + String(secondKey)
                }
            }
        }
        return nil
    }
}

/// Mirrors InputController.apply so tests can see what the field would show.
private struct Paper {
    var committed = ""
    var marked = ""
    var text: String { committed + marked }

    mutating func apply(_ field: FieldEdit) {
        switch field {
        case .none:
            break
        case .unmark(let string):
            committed += string
            marked = ""
        case .insert(let string):
            committed += string
            marked = ""
        case .mark(let string):
            marked = string
        case .replaceBeforeCaret(let utf16, let string):
            removeBeforeCaret(utf16)
            marked = string
        case .insertThenMark(let insert, let mark):
            committed += insert
            marked = mark
        case .insertReplacing(let utf16, let string):
            removeBeforeCaret(utf16)
            committed += string
            marked = ""
        case .insertReplacingThenMark(let utf16, let insert, let mark):
            committed = dropEnd(committed, utf16) + insert
            marked = mark
        case .clearMarkThenInsert(let utf16, let string):
            removeBeforeCaret(utf16 + utf16Count(marked))
            committed += string
            marked = ""
        case .clearMarkThenMark(let utf16, let string):
            removeBeforeCaret(utf16 + utf16Count(marked))
            marked = string
        case .rewrite(let utf16, let string, let thenMark):
            var left = utf16
            let markUnits = utf16Count(marked)
            if left > 0 {
                let take = min(left, markUnits)
                marked = dropEnd(marked, take)
                left -= take
            }
            if left > 0 {
                committed = dropEnd(committed, left)
            }
            committed += string
            marked = thenMark
        }
    }

    mutating func deleteOne() {
        if marked.isEmpty {
            committed = dropEnd(committed, 1)
        } else {
            marked = dropEnd(marked, 1)
        }
    }

    /// `utf16` is counted back from the caret, through the mark and then the
    /// committed text. One client call replaces that span.
    private mutating func removeBeforeCaret(_ utf16: Int) {
        let fromMark = min(utf16, utf16Count(marked))
        marked = dropEnd(marked, fromMark)
        let fromCommitted = utf16 - fromMark
        if fromCommitted > 0 {
            committed = dropEnd(committed, fromCommitted)
        }
    }
}

private func utf16Count(_ text: String) -> Int {
    (text as NSString).length
}

private func dropEnd(_ text: String, _ utf16: Int) -> String {
    let ns = text as NSString
    return ns.substring(to: max(0, ns.length - utf16))
}

private extension Session {
    func type(_ text: String) -> String {
        for character in text {
            _ = input(character)
        }
        return document
    }
}

@Test func deundaStaysUncorrectedAtWordBoundaries() throws {
    for word in ["든다", "든다는", "든다만", "듣다"] {
        let keys = try #require(SebeolKeys.keys(for: word))
        for boundary in [" ", ".", ",", "\n"] {
            let session = Session(lexicon: lexicon, mode: .korean)
            #expect(session.type(keys + boundary) == word + boundary)
        }
    }
}

@Test func yeoreoseoStaysUncorrectedAtWordBoundaries() throws {
    for word in ["열어서", "열어서는", "열어서도", "열에서"] {
        let keys = try #require(SebeolKeys.keys(for: word))
        for boundary in [" ", ".", ",", "\n"] {
            let session = Session(lexicon: lexicon, mode: .korean)
            #expect(session.type(keys + boundary) == word + boundary)
        }
    }
}

@Test func dugaeStaysUncorrectedAtWordBoundaries() throws {
    for word in ["두개", "두개는", "두개를", "두개만", "대개"] {
        let keys = try #require(SebeolKeys.keys(for: word))
        for boundary in [" ", ".", ",", "\n"] {
            let session = Session(lexicon: lexicon, mode: .korean)
            #expect(session.type(keys + boundary) == word + boundary)
        }
    }
}

@Test func malhanStaysUncorrectedAtWordBoundaries() throws {
    for word in ["말한", "말만"] {
        let keys = try #require(SebeolKeys.keys(for: word))
        for boundary in [" ", ".", ",", "\n"] {
            let session = Session(lexicon: lexicon, mode: .korean)
            #expect(session.type(keys + boundary) == word + boundary)
        }
    }
}

@Test func bogeStaysUncorrectedAtWordBoundaries() throws {
    for word in ["보게", "보게는", "보게도", "보고"] {
        let keys = try #require(SebeolKeys.keys(for: word))
        for boundary in [" ", ".", ",", "\n"] {
            let session = Session(lexicon: lexicon, mode: .korean)
            #expect(session.type(keys + boundary) == word + boundary)
        }
    }
}

@Test func geureoneunStaysUncorrectedAtWordBoundaries() throws {
    for word in ["그러는", "그러는데", "그래"] {
        let keys = try #require(SebeolKeys.keys(for: word))
        for boundary in [" ", ".", ",", "\n"] {
            let session = Session(lexicon: lexicon, mode: .korean)
            #expect(session.type(keys + boundary) == word + boundary)
        }
    }
}

@Test func geoyaStaysUncorrectedAtWordBoundaries() throws {
    for word in ["거야", "거의"] {
        let keys = try #require(SebeolKeys.keys(for: word))
        for boundary in [" ", ".", ",", "\n"] {
            let session = Session(lexicon: lexicon, mode: .korean)
            #expect(session.type(keys + boundary) == word + boundary)
        }
    }
}

@Test func haetjimanStaysUncorrectedAtWordBoundaries() throws {
    for word in ["했지만", "했죠"] {
        let keys = try #require(SebeolKeys.keys(for: word))
        for boundary in [" ", ".", ",", "\n"] {
            let session = Session(lexicon: lexicon, mode: .korean)
            #expect(session.type(keys + boundary) == word + boundary)
        }
    }
}

@Test func haenneStaysUncorrectedAtWordBoundaries() throws {
    for word in ["했네", "했네요"] {
        let keys = try #require(SebeolKeys.keys(for: word))
        for boundary in [" ", ".", ",", "\n"] {
            let session = Session(lexicon: lexicon, mode: .korean)
            #expect(session.type(keys + boundary) == word + boundary)
        }
    }
}
