import Foundation
import Combine
import Security

struct SSHServerEndpoint: Codable, Equatable {
    let host: String
    let port: Int
    let username: String

    var address: String { (host.contains(":") ? "[\(host)]" : host) + (port == 22 ? "" : ":\(port)") }
    var label: String { "\(username)@\(address)" }

    static func parse(address: String, username: String) throws -> Self {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: raw.contains("://") ? raw : "ssh://" + raw),
              url.scheme == "ssh", let host = url.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", (1...65535).contains(url.port ?? 22) else {
            throw SSHServerError.invalidAddress
        }
        let user = url.user ?? username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { throw SSHServerError.missingUsername }
        // URLComponents includes brackets for IPv6 literals; NIO needs the bare host.
        let normalizedHost = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return Self(host: normalizedHost.lowercased(), port: url.port ?? 22, username: user)
    }
}

struct SSHServer: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var endpoint: SSHServerEndpoint
    var remembersPassword: Bool
}

enum SSHServerError: LocalizedError {
    case invalidAddress, missingUsername, duplicateServer, invalidPassword, keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "SSH 서버 주소와 포트를 확인하세요."
        case .missingUsername: "사용자 이름을 입력하세요."
        case .duplicateServer: "같은 주소·포트·사용자의 서버가 이미 저장되어 있습니다. 목록에서 해당 서버를 선택하세요."
        case .invalidPassword: "저장된 비밀번호를 읽을 수 없습니다. 다시 입력하세요."
        case .keychain(let status): "비밀번호 키체인 처리에 실패했습니다. (\(status))"
        }
    }
}

@MainActor
protocol SSHPasswordStorage {
    func password(for id: UUID) throws -> String?
    func setPassword(_ password: String, for id: UUID) throws
    func removePassword(for id: UUID) throws
}

/// App-private, device-only credentials. No shared keyboard access or iCloud sync.
@MainActor
struct SSHKeychain: SSHPasswordStorage {
    var service = "com.ias.seto.ssh.password"

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    func password(for id: UUID) throws -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SSHServerError.keychain(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw SSHServerError.invalidPassword
        }
        return password
    }

    func setPassword(_ password: String, for id: UUID) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(id).merging(attributes) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SSHServerError.keychain(status) }
    }

    func removePassword(for id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SSHServerError.keychain(status) }
    }
}

@MainActor
final class SSHServerStore: ObservableObject {
    @Published private(set) var servers: [SSHServer]
    private let defaults: UserDefaults
    private let passwords: any SSHPasswordStorage
    private let storageKey = "ssh.servers.v1"

    init(defaults: UserDefaults = .standard, passwords: any SSHPasswordStorage = SSHKeychain()) {
        self.defaults = defaults
        self.passwords = passwords
        if let data = defaults.data(forKey: storageKey) {
            servers = (try? JSONDecoder().decode([SSHServer].self, from: data)) ?? []
        } else if let address = defaults.string(forKey: "ssh.address"),
                  let endpoint = try? SSHServerEndpoint.parse(address: address, username: defaults.string(forKey: "ssh.user") ?? "") {
            servers = [SSHServer(id: UUID(), name: endpoint.label, endpoint: endpoint, remembersPassword: false)]
            persist()
        } else { servers = [] }
    }

    func password(for server: SSHServer) throws -> String? {
        guard server.remembersPassword else { return nil }
        return try passwords.password(for: server.id)
    }

    @discardableResult
    func save(id: UUID?, name: String, endpoint: SSHServerEndpoint, password: String, rememberPassword: Bool) throws -> SSHServer {
        let existing = servers.first { $0.id == id }
        let matching = servers.first { $0.endpoint == endpoint }
        if let existing, let matching, existing.id != matching.id { throw SSHServerError.duplicateServer }
        let serverID = existing?.id ?? matching?.id ?? UUID()
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = SSHServer(id: serverID, name: title.isEmpty ? endpoint.label : title,
                               endpoint: endpoint, remembersPassword: rememberPassword)
        // A failed credential change must not be reported as a successful save.
        if rememberPassword { try passwords.setPassword(password, for: serverID) }
        else if (existing ?? matching)?.remembersPassword == true { try passwords.removePassword(for: serverID) }
        if let index = servers.firstIndex(where: { $0.id == serverID }) { servers[index] = server }
        else { servers.append(server) }
        persist()
        return server
    }

    func remove(_ server: SSHServer) throws {
        if server.remembersPassword { try passwords.removePassword(for: server.id) }
        servers.removeAll { $0.id == server.id }
        persist()
    }

    private func persist() {
        // SSHServer intentionally has no password field.
        defaults.set(try? JSONEncoder().encode(servers), forKey: storageKey)
    }
}

@MainActor
final class SSHServerForm: ObservableObject {
    @Published var serverID: UUID?
    @Published var name = ""
    @Published var address = "" { didSet { clearMismatchedPassword() } }
    @Published var username = "" { didSet { clearMismatchedPassword() } }
    @Published var password = ""
    @Published var rememberPassword = false
    private var loadedEndpoint: SSHServerEndpoint?

    func load(_ server: SSHServer, from store: SSHServerStore) throws {
        // Read before changing the form, so a Keychain error leaves the draft intact.
        let savedPassword = try store.password(for: server)
        reset()
        serverID = server.id
        name = server.name
        address = server.endpoint.address
        username = server.endpoint.username
        rememberPassword = server.remembersPassword
        password = savedPassword ?? ""
        loadedEndpoint = server.endpoint
    }

    func reset() {
        loadedEndpoint = nil
        serverID = nil; name = ""; address = ""; username = ""; password = ""; rememberPassword = false
    }

    func save(to store: SSHServerStore) throws -> SSHServer {
        let endpoint = try SSHServerEndpoint.parse(address: address, username: username)
        let server = try store.save(id: serverID, name: name, endpoint: endpoint, password: password, rememberPassword: rememberPassword)
        serverID = server.id
        name = server.name
        loadedEndpoint = endpoint
        return server
    }

    private func clearMismatchedPassword() {
        guard let loadedEndpoint, (try? SSHServerEndpoint.parse(address: address, username: username)) != loadedEndpoint else { return }
        password = ""
        self.loadedEndpoint = nil
    }
}
