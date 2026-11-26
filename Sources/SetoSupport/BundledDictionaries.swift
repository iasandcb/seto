import Foundation

/// Installs the editable copies of the bundled word lists.
///
/// The input menu opens `english-words.txt`, `english-extra.txt`,
/// `korean-words.txt`, and `korean-valid.txt` under Application Support and
/// expects people to add or remove lines there. Those copies exist so edits
/// survive quitting the input method. Learned words (`LearnedWords` in
/// UserDefaults) and the typo log (`typos.jsonl`) are separate and are never
/// written here.
///
/// A hash of each bundled file is stored in `.bundled-revision`. While the
/// hash matches, the copy is left alone. When an update ships a different
/// list, an unmodified copy is replaced. Lines a person added or removed are
/// applied on top of the new list. The previous copy is saved as `*.bak`
/// first whenever that rewrite would discard bytes they may have changed.
/// `.bundled/` keeps the list that was installed, so a later update can tell
/// those edits from words the old bundle already contained.
public enum BundledDictionaries {
    public static let filenames = [
        "english-words.txt",
        "english-extra.txt",
        "korean-words.txt",
        "korean-valid.txt",
    ]

    static let revisionFilename = ".bundled-revision"
    static let snapshotDirectoryName = ".bundled"
    static let backupSuffix = ".bak"

    /// SHA-256 of every `Resources/` revision shipped before copies recorded a
    /// hash. An unmodified Application Support file from one of those builds
    /// is replaced outright. Later builds identify their own copies with
    /// `.bundled-revision`, so new list revisions do not need to be added here.
    static let shippedBundleHashes: Set<String> = [
        "1036ab48cb7cc107dd7362673e9c887ae6948d49c8dac2ccbb30f69e63c3c4d8",
        "33f47847b434a69eea210f55c3b7de25b7137d4a28453a72cee572cb7c814554",
        "3a5ac105965904abd93794885d309c4528ae839f355f0995243f687dde6287e1",
        "5113f6a729f6065976a6dba164a54af8764c0e909a01da53edb7032a2918a261",
        "5233e1c3fccfa6a8645e58cb36c8b64e43c6cf91ae3ae7d3ae5202413c4826fe",
        "5733dde7308a9fa53fc111205d6e6b9cad14dce68b35fd77ba92bec7a9186f31",
        "64272f97cb44a4e97a5f0c1b458eb3438d533c1cff81beb2e080198116fb67be",
        "7744984dc5edd8b0b0e278f9b834285aedb41379e828603b5988edbeb5ffb032",
        "8b08ba38d3b7a5fc9cfc8611a8ae659bd44be95c372ff118b5fe1b39dade5575",
        "8c0473a13c9dc937430e85d7d8efc10b5fdf20b8077ebb06eebf055cd0d44353",
        "8e3aff1d4d3092c319c7822dd111cb2d506aeff353f416b200c4a5d6e78349d1",
        "8ff9588893ecc1867de8928f15e9a727d52970b7b4028a3ab1dc553a665afc4d",
        "90cce09b8e4be907e85f8d0162f248ca141c624a98e054756661d93a73e9126b",
        "a0cf636ddcb67f22a8f42b9f51e3158e66d76c02a6de93328224e098da09edc8",
        "a63feb78c42c80a78578d2bfc5b2a509e7d3de2c02134792ae6d34d853d81e7c",
        "a911e2d301b8f1af1c91d3bdd894d2268910acafb1739b803ca0c6a0056bd37a",
        "b3eba1e81e88ab4cbaa61bc934ccbd7718cb8008511a0c4690f29d71f6b48433",
        "b9c60065647496ffa50dfb2d3b93b03d9dac59ba960243919f410da026a0488d",
        "c8cc3f8fab4905bc14062cb1599300cd9d4b420e82035407254cf64f3490eb6d",
        "d3877c4bd20ac73b825ec70bc60971c446c496cb7ea492e31c3e75571aa2ecc2",
        "d75693c2bcceae908997d21b697d7b812339c9a31560546bb843c72645f249c7",
    ]

    /// Copies missing lists into `directory` and refreshes any list whose
    /// bundled bytes differ from the last install.
    public static func sync(from bundle: URL, to directory: URL) throws {
        try sync(from: bundle, to: directory, knownBundleHashes: shippedBundleHashes)
    }

    /// - Parameter knownBundleHashes: Digests of unmodified bundles that
    ///   predate the revision file.
    static func sync(
        from bundle: URL,
        to directory: URL,
        knownBundleHashes: Set<String>
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshots = directory.appendingPathComponent(snapshotDirectoryName, isDirectory: true)
        try manager.createDirectory(at: snapshots, withIntermediateDirectories: true)
        var revision = readRevision(at: directory)
        for filename in filenames {
            let didChange = try syncFile(
                filename,
                bundle: bundle,
                directory: directory,
                snapshots: snapshots,
                revision: &revision,
                knownBundleHashes: knownBundleHashes
            )
            if didChange {
                try writeRevision(revision, to: directory)
            }
        }
    }

    static func digestHex(_ data: Data) -> String {
        DictionaryDigest.hex(data)
    }

    private static func syncFile(
        _ filename: String,
        bundle: URL,
        directory: URL,
        snapshots: URL,
        revision: inout [String: String],
        knownBundleHashes: Set<String>
    ) throws -> Bool {
        let manager = FileManager.default
        let bundleURL = bundle.appendingPathComponent(filename)
        guard manager.fileExists(atPath: bundleURL.path) else { return false }
        let bundleData = try Data(contentsOf: bundleURL)
        let bundleHash = DictionaryDigest.hex(bundleData)
        let destination = directory.appendingPathComponent(filename)
        let snapshotURL = snapshots.appendingPathComponent(filename)
        let recorded = revision[filename]

        if !manager.fileExists(atPath: destination.path) {
            // Rename-over keeps any live memory map of the previous inode.
            try writeAtomically(bundleData, to: destination)
            try writeAtomically(bundleData, to: snapshotURL)
            revision[filename] = bundleHash
            return true
        }
        if recorded == bundleHash {
            return false
        }

        let destinationData = try Data(contentsOf: destination)
        let destinationHash = DictionaryDigest.hex(destinationData)
        let unmodified = destinationData == bundleData
            || destinationHash == recorded
            || (recorded == nil && knownBundleHashes.contains(destinationHash))
        if unmodified {
            if destinationData != bundleData {
                try writeAtomically(bundleData, to: destination)
            }
            try writeAtomically(bundleData, to: snapshotURL)
            revision[filename] = bundleHash
            return true
        }

        // Snapshot already matches this bundle: a previous attempt wrote the
        // files and stopped before the marker. The destination is already the
        // refreshed list, edits included.
        if manager.fileExists(atPath: snapshotURL.path) {
            let snapshotData = try Data(contentsOf: snapshotURL)
            if DictionaryDigest.hex(snapshotData) == bundleHash {
                revision[filename] = bundleHash
                return true
            }
        }

        let merged = try mergedList(
            destination: destinationData,
            snapshot: snapshotURL,
            recorded: recorded,
            bundle: bundleData
        )
        if merged != destinationData {
            try writeAtomically(destinationData, to: directory.appendingPathComponent(filename + backupSuffix))
            try writeAtomically(merged, to: destination)
        }
        try writeAtomically(bundleData, to: snapshotURL)
        revision[filename] = bundleHash
        return true
    }

    private static func mergedList(
        destination: Data,
        snapshot snapshotURL: URL,
        recorded: String?,
        bundle: Data
    ) throws -> Data {
        let manager = FileManager.default
        guard manager.fileExists(atPath: snapshotURL.path) else {
            return mergeKeepingExtras(user: destination, new: bundle)
        }
        let snapshot = try Data(contentsOf: snapshotURL)
        let snapshotHash = DictionaryDigest.hex(snapshot)
        // Trust the snapshot when it is the bundle we last recorded, or when
        // the marker was lost and the snapshot is still an older list.
        let trusted = snapshotHash == recorded || (recorded == nil && snapshotHash != DictionaryDigest.hex(bundle))
        if trusted {
            return merge(old: snapshot, user: destination, new: bundle)
        }
        return mergeKeepingExtras(user: destination, new: bundle)
    }

    /// Three-way word merge. Additions and deletions are lines in the user's
    /// file that differ from the list we last installed.
    private static func merge(old: Data, user: Data, new: Data) -> Data {
        let oldWords = dictionaryWords(in: old)
        let userWords = dictionaryWords(in: user)
        let added = userWords.subtracting(oldWords)
        let removed = oldWords.subtracting(userWords)
        var kept = dictionaryWords(in: new).subtracting(removed)
        kept.formUnion(added)
        return render(header: header(of: new), words: kept)
    }

    /// Legacy copy with no recorded bundle. Keep every extra line. Absence
    /// from the file is not treated as a deletion, because the previous
    /// bundle is unknown and new words would look the same.
    private static func mergeKeepingExtras(user: Data, new: Data) -> Data {
        var kept = dictionaryWords(in: new)
        kept.formUnion(dictionaryWords(in: user))
        return render(header: header(of: new), words: kept)
    }

    private static func dictionaryWords(in data: Data) -> Set<String> {
        let text = String(decoding: data, as: UTF8.self)
        var words: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            words.insert(trimmed.precomposedStringWithCanonicalMapping)
        }
        return words
    }

    /// Leading comment and blank lines. `korean-valid.txt` is mapped as a
    /// sorted word list, so this header has to stay in front of the body.
    private static func header(of data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        var lines: [Substring] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") { break }
            lines.append(line)
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines.map(String.init).joined(separator: "\n")
    }

    private static func render(header: String, words: Set<String>) -> Data {
        var text = ""
        if !header.isEmpty {
            text += header
            text += "\n"
        }
        for word in words.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            text += word
            text += "\n"
        }
        return Data(text.utf8)
    }

    private static func readRevision(at directory: URL) -> [String: String] {
        let url = directory.appendingPathComponent(revisionFilename)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, filenames.contains(parts[0]) else { continue }
            let hash = parts[1].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            map[parts[0]] = hash
        }
        return map
    }

    private static func writeRevision(_ revision: [String: String], to directory: URL) throws {
        let lines = filenames.compactMap { name -> String? in
            guard let hash = revision[name] else { return nil }
            return "\(name) \(hash)"
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try writeAtomically(Data(text.utf8), to: directory.appendingPathComponent(revisionFilename))
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

/// SHA-256 of a word list. Foundation has no digest API that is present on
/// every platform this module builds for, and the files are a few megabytes.
private enum DictionaryDigest {
    static func hex(_ data: Data) -> String {
        var message = [UInt8](data)
        let bitCount = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }

        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        for offset in stride(from: 0, to: message.count, by: 64) {
            var schedule = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                schedule[index] = (UInt32(message[start]) << 24)
                    | (UInt32(message[start + 1]) << 16)
                    | (UInt32(message[start + 2]) << 8)
                    | UInt32(message[start + 3])
            }
            for index in 16..<64 {
                let small = schedule[index - 15]
                let large = schedule[index - 2]
                let s0 = rotate(small, 7) ^ rotate(small, 18) ^ (small >> 3)
                let s1 = rotate(large, 17) ^ rotate(large, 19) ^ (large >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
            var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choose = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choose &+ roundConstants[index] &+ schedule[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
        }

        var hex = ""
        hex.reserveCapacity(64)
        for value in hash {
            hex += String(format: "%08x", value)
        }
        return hex
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
}
