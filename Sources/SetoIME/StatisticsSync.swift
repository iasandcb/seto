import AppKit
import CloudKit
import Security
import SetoCore

/// One writer per installation. Each upload replaces that installation's snapshot.
@MainActor
final class StatisticsSync {
    static let shared = StatisticsSync()
    private static let containerIdentifier = "iCloud.com.ias.seto"
    private let defaults = UserDefaults.standard
    private let deviceID: String
    private var remote: [String: [String: TypingStatistics.Counts]] = [:]
    private var generation = UUID()
    private var accountID: String?
    private var running = false
    private var timer: Timer?
    private var accountObserver: NSObjectProtocol?
    private var lastSynced: String?
    private(set) var status = "iCloud: 서명 설정 필요" {
        didSet { NSLog("Seto statistics: %@", status) }
    }
    private var container: CKContainer?

    private init() {
        let key = "statistics.deviceID.v1"
        deviceID = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(deviceID, forKey: key)
        // Calling CloudKit without entitlements can terminate the process.
        if let task = SecTaskCreateFromSelf(nil),
           let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String],
           services.contains("CloudKit"),
           let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
           containers.contains(Self.containerIdentifier) {
            container = CKContainer(identifier: Self.containerIdentifier)
            status = "iCloud: 동기화 대기"
        }
    }

    func start() {
        guard timer == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let sync = StatisticsSync.shared
                sync.generation = UUID()
                sync.remote = [:]
                sync.accountID = nil
                sync.lastSynced = nil
                sync.status = "iCloud: 계정 확인 중"
                sync.sync()
            }
        }
        sync()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in StatisticsSync.shared.sync() }
        }
    }

    func combinedHistory() -> [String: TypingStatistics.Counts] {
        var devices = remote
        devices[deviceID] = SharedTypingStatistics.store.dailyHistory()
        return TypingStatistics.combined(Array(devices.values))
    }

    func sync() {
        guard let container, !running else { return }
        running = true
        let requestGeneration = generation
        Task {
            defer { running = false }
            do {
                guard try await container.accountStatus() == .available else {
                    remote = [:]
                    status = "iCloud: 계정 로그인 필요"
                    return
                }
                // Do not retain another account's records if the iCloud account changes.
                let user = try await container.userRecordID().recordName
                guard generation == requestGeneration else { return }
                if accountID != user {
                    remote = [:]
                    accountID = user
                    if let data = defaults.data(forKey: "statistics.cloudCache." + user),
                       let cached = try? JSONDecoder().decode([String: [String: TypingStatistics.Counts]].self, from: data) {
                        remote = cached
                    }
                }
                let database = container.privateCloudDatabase
                let id = CKRecord.ID(recordName: "mac-" + deviceID)
                let record: CKRecord
                do { record = try await database.record(for: id) }
                catch let error as CKError where error.code == .unknownItem {
                    record = CKRecord(recordType: "MacTypingStatistics", recordID: id)
                }
                guard generation == requestGeneration else { return }
                record["history"] = try JSONEncoder().encode(SharedTypingStatistics.store.dailyHistory()) as CKRecordValue
                _ = try await database.save(record)
                var page = try await database.records(matching: CKQuery(recordType: "MacTypingStatistics", predicate: NSPredicate(value: true)))
                var fetched: [String: [String: TypingStatistics.Counts]] = [:]
                while true {
                    for (recordID, value) in page.matchResults {
                        let entry = try value.get()
                        guard let data = entry["history"] as? Data else { continue }
                        let history = try JSONDecoder().decode([String: TypingStatistics.Counts].self, from: data)
                        guard history.values.allSatisfy({ $0.typed >= 0 && $0.backspaces >= 0 }) else { continue }
                        fetched[String(recordID.recordName.dropFirst(4))] = history
                    }
                    guard let cursor = page.queryCursor else { break }
                    page = try await database.records(continuingMatchFrom: cursor)
                }
                guard generation == requestGeneration else { return }
                remote = fetched
                defaults.set(try JSONEncoder().encode(fetched), forKey: "statistics.cloudCache." + user)
                lastSynced = Date().formatted(date: .omitted, time: .shortened)
                status = "iCloud: \(lastSynced!) 동기화 · \(Set(fetched.keys).union([deviceID]).count)대"
            } catch {
                guard generation == requestGeneration else { return }
                status = "iCloud: 동기화 실패" + (lastSynced.map { " · 마지막 성공 \($0)" } ?? "") + " · \(error.localizedDescription)"
            }
        }
    }
}
