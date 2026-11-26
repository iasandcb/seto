import Foundation
import Testing
@testable import SetoSupport

@Test func dictionaryDigestMatchesSHA256() {
    #expect(BundledDictionaries.digestHex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(BundledDictionaries.digestHex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let block = String(repeating: "a", count: 1000)
    #expect(BundledDictionaries.digestHex(Data(block.utf8)) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    #expect(BundledDictionaries.shippedBundleHashes.count == 21)
    let hexDigits = Set("0123456789abcdef")
    for hash in BundledDictionaries.shippedBundleHashes {
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { hexDigits.contains($0) })
        #expect(hash == hash.lowercased())
    }
}

@Test func missingDictionaryCopiesAreCreatedAndLaterEditsStay() throws {
    let box = try DictionarySandbox()
    defer { box.remove() }
    try box.writeBundle("english-extra.txt", "apple\nbanana\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])
    #expect(try box.text("english-extra.txt") == "apple\nbanana\n")

    try box.writeInstalled("english-extra.txt", "apple\nbanana\ncustom\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])
    #expect(try box.text("english-extra.txt") == "apple\nbanana\ncustom\n")
    #expect(!box.exists("english-extra.txt" + BundledDictionaries.backupSuffix))
}

@Test func unmodifiedCopyIsReplacedWhenTheBundleChanges() throws {
    let box = try DictionarySandbox()
    defer { box.remove() }
    try box.writeBundle("korean-words.txt", "안녕\n한글\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])
    try box.writeBundle("korean-words.txt", "세벌식\n안녕\n한글\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])
    #expect(try box.text("korean-words.txt") == "세벌식\n안녕\n한글\n")
    #expect(!box.exists("korean-words.txt" + BundledDictionaries.backupSuffix))
    #expect(try box.snapshot("korean-words.txt") == "세벌식\n안녕\n한글\n")
}

@Test func userAdditionsAndDeletionsSurviveLaterBundleRevisions() throws {
    let box = try DictionarySandbox()
    defer { box.remove() }
    try box.writeBundle("english-words.txt", "apple\nbanana\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])
    try box.writeInstalled("english-words.txt", "apple\ncherry\n")
    try box.writeBundle("english-words.txt", "apple\nbanana\ndate\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])

    #expect(try box.words("english-words.txt") == ["apple", "cherry", "date"])
    #expect(try box.words("english-words.txt" + BundledDictionaries.backupSuffix) == ["apple", "cherry"])
    #expect(try box.snapshot("english-words.txt") == "apple\nbanana\ndate\n")

    try box.writeInstalled("english-words.txt", try box.text("english-words.txt") + "extra\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])
    #expect(try box.words("english-words.txt") == ["apple", "cherry", "date", "extra"])

    try box.writeBundle("english-words.txt", "apple\nbanana\ndate\nfig\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])
    #expect(try box.words("english-words.txt") == ["apple", "cherry", "date", "extra", "fig"])
}

@Test func knownUnmodifiedBundleIsReplacedWithoutKeepingRemovedWords() throws {
    let box = try DictionarySandbox()
    defer { box.remove() }
    let previous = "alpha\nbeta\n"
    let hash = BundledDictionaries.digestHex(Data(previous.utf8))
    try box.writeInstalled("korean-valid.txt", previous)
    try box.writeBundle("korean-valid.txt", "alpha\ngamma\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [hash])
    #expect(try box.words("korean-valid.txt") == ["alpha", "gamma"])
    #expect(!box.exists("korean-valid.txt" + BundledDictionaries.backupSuffix))
}

@Test func legacyEditedCopyKeepsAddedLinesAndSavesThePreviousFile() throws {
    let box = try DictionarySandbox()
    defer { box.remove() }
    try box.writeInstalled("english-extra.txt", "alpha\ncustom\n")
    try box.writeBundle("english-extra.txt", "alpha\nbeta\ngamma\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])
    // Without the previous bundle, a missing line cannot be told from a word
    // the update added, so `beta` stays. The added line is kept, and the
    // previous file is the backup.
    #expect(try box.words("english-extra.txt") == ["alpha", "beta", "custom", "gamma"])
    #expect(try box.text("english-extra.txt" + BundledDictionaries.backupSuffix) == "alpha\ncustom\n")
    #expect(try box.snapshot("english-extra.txt") == "alpha\nbeta\ngamma\n")
}

@Test func refreshedListKeepsTheNewHeaderAndStaysStrictlySorted() throws {
    let box = try DictionarySandbox()
    defer { box.remove() }
    try box.writeBundle("korean-valid.txt", "# old\napple\nbanana\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])
    let composed = "\u{1100}\u{1161}"
    try box.writeInstalled("korean-valid.txt", "# old\nbanana\napricot\n\(composed)\n")
    try box.writeBundle("korean-valid.txt", "# keep\n# added\napple\nbanana\ndate\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])

    let text = try box.text("korean-valid.txt")
    #expect(text == "# keep\n# added\napricot\nbanana\ndate\n가\n")
    let body = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") }
    #expect(body == ["apricot", "banana", "date", "가"])
    for pair in zip(body, body.dropFirst()) {
        #expect(Data(pair.0.utf8).lexicographicallyPrecedes(Data(pair.1.utf8)))
    }
}

@Test func absentBundledFileDoesNotRemoveTheInstalledCopy() throws {
    let box = try DictionarySandbox()
    defer { box.remove() }
    try box.writeInstalled("korean-words.txt", "한글\n")
    try box.writeInstalled("typos.jsonl", "{\"kept\":true}\n")
    try box.writeBundle("english-extra.txt", "ssh\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])
    #expect(try box.text("korean-words.txt") == "한글\n")
    #expect(try box.text("typos.jsonl") == "{\"kept\":true}\n")
    #expect(try box.words("english-extra.txt") == ["ssh"])
}

@Test func retryAfterTheSnapshotWasWrittenKeepsADeletion() throws {
    let box = try DictionarySandbox()
    defer { box.remove() }
    try box.writeBundle("english-extra.txt", "apple\nbanana\n")
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])
    let revision = box.installed.appendingPathComponent(BundledDictionaries.revisionFilename)
    let recorded = try String(contentsOf: revision, encoding: .utf8)
    try box.writeBundle("english-extra.txt", "apple\nbanana\ndate\n")
    try box.writeInstalled("english-extra.txt", "apple\ncherry\ndate\n")
    try Data("apple\nbanana\ndate\n".utf8).write(to: box.snapshotURL("english-extra.txt"))
    try Data(recorded.utf8).write(to: revision)
    try BundledDictionaries.sync(from: box.bundle, to: box.installed, knownBundleHashes: [])
    #expect(try box.words("english-extra.txt") == ["apple", "cherry", "date"])
    let marker = try String(contentsOf: revision, encoding: .utf8)
    #expect(marker.contains(BundledDictionaries.digestHex(Data("apple\nbanana\ndate\n".utf8))))
}

private struct DictionarySandbox {
    let root: URL
    let bundle: URL
    let installed: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seto-dicts-\(UUID().uuidString)", isDirectory: true)
        bundle = root.appendingPathComponent("bundle", isDirectory: true)
        installed = root.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    }

    func writeBundle(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: bundle.appendingPathComponent(name))
    }

    func writeInstalled(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: installed.appendingPathComponent(name))
    }

    func text(_ name: String) throws -> String {
        let data = try Data(contentsOf: installed.appendingPathComponent(name))
        return String(decoding: data, as: UTF8.self)
    }

    func words(_ name: String) throws -> Set<String> {
        Set(try text(name).split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    func snapshot(_ name: String) throws -> String {
        let data = try Data(contentsOf: snapshotURL(name))
        return String(decoding: data, as: UTF8.self)
    }

    func snapshotURL(_ name: String) -> URL {
        installed
            .appendingPathComponent(BundledDictionaries.snapshotDirectoryName, isDirectory: true)
            .appendingPathComponent(name)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: installed.appendingPathComponent(name).path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
