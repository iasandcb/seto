import XCTest
import Security
@testable import Sebeol390

@MainActor
private final class MemorySSHPasswords: SSHPasswordStorage {
    var values: [UUID: String] = [:]
    var fails = false
    func password(for id: UUID) throws -> String? {
        if fails { throw SSHServerError.keychain(errSecInteractionNotAllowed) }
        return values[id]
    }
    func setPassword(_ password: String, for id: UUID) throws {
        if fails { throw SSHServerError.keychain(errSecInteractionNotAllowed) }
        values[id] = password
    }
    func removePassword(for id: UUID) throws {
        if fails { throw SSHServerError.keychain(errSecInteractionNotAllowed) }
        values.removeValue(forKey: id)
    }
}

@MainActor
final class SSHServerStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "SSHServerStoreTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    private func endpoint(_ address: String = "example.com", _ user: String = "alex") throws -> SSHServerEndpoint {
        try .parse(address: address, username: user)
    }

    func testEndpointValidationAndIPv6() throws {
        XCTAssertEqual(try endpoint(" ssh://alex@EXAMPLE.com:2222/ ", "ignored"),
                       SSHServerEndpoint(host: "example.com", port: 2222, username: "alex"))
        let ipv6 = try endpoint("[::1]:2222")
        XCTAssertEqual(ipv6.host, "::1")
        XCTAssertEqual(ipv6.address, "[::1]:2222")
        XCTAssertEqual(try endpoint(ipv6.address), ipv6)
        for invalid in ["", "https://example.com", "ssh://alex:secret@example.com", "example.com:0", "example.com:65536", "example.com/path", "example.com?q=1", "example.com#fragment", "bad host"] {
            XCTAssertThrowsError(try endpoint(invalid), invalid)
        }
        XCTAssertThrowsError(try endpoint("example.com", " "))
    }

    func testMultipleServersPersistWithoutPasswordsAndReloadCredentialsSeparately() throws {
        let defaults = defaults(), passwords = MemorySSHPasswords()
        let store = SSHServerStore(defaults: defaults, passwords: passwords)
        let first = try store.save(id: nil, name: "개발", endpoint: endpoint(), password: "unique-secret-123", rememberPassword: true)
        let second = try store.save(id: nil, name: "운영", endpoint: endpoint("prod.example.com:2222"), password: "temporary-secret", rememberPassword: false)
        let data = try XCTUnwrap(defaults.data(forKey: "ssh.servers.v1"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("unique-secret-123"))
        XCTAssertFalse(json.contains("temporary-secret"))
        let recovered = SSHServerStore(defaults: defaults, passwords: passwords)
        XCTAssertEqual(recovered.servers, [first, second])
        XCTAssertEqual(try recovered.password(for: first), "unique-secret-123")
        XCTAssertNil(try recovered.password(for: second))
        XCTAssertNil(passwords.values[second.id])
    }

    func testSameEndpointUpdatesButDifferentUsersAndPortsStaySeparate() throws {
        let store = SSHServerStore(defaults: defaults(), passwords: MemorySSHPasswords())
        let first = try store.save(id: nil, name: "first", endpoint: endpoint(), password: "one", rememberPassword: true)
        let updated = try store.save(id: nil, name: "renamed", endpoint: endpoint("EXAMPLE.com:22"), password: "two", rememberPassword: true)
        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(try store.password(for: updated), "two")
        _ = try store.save(id: nil, name: "", endpoint: endpoint("example.com", "root"), password: "", rememberPassword: false)
        _ = try store.save(id: nil, name: "", endpoint: endpoint("example.com:2222"), password: "", rememberPassword: false)
        XCTAssertEqual(store.servers.count, 3)
        XCTAssertThrowsError(try store.save(id: first.id, name: "", endpoint: endpoint("example.com", "root"), password: "", rememberPassword: false))
        XCTAssertEqual(store.servers.first?.name, "renamed")
    }

    func testOptOutAndDeleteRemoveCredentialsAndSurviveReload() throws {
        let defaults = defaults(), passwords = MemorySSHPasswords()
        let store = SSHServerStore(defaults: defaults, passwords: passwords)
        let server = try store.save(id: nil, name: "", endpoint: endpoint(), password: "saved", rememberPassword: true)
        let updated = try store.save(id: server.id, name: "", endpoint: server.endpoint, password: "temporary", rememberPassword: false)
        XCTAssertFalse(updated.remembersPassword)
        XCTAssertNil(passwords.values[server.id])
        let saved = try store.save(id: server.id, name: "", endpoint: server.endpoint, password: "saved-again", rememberPassword: true)
        try store.remove(saved)
        XCTAssertNil(passwords.values[server.id])
        XCTAssertTrue(SSHServerStore(defaults: defaults, passwords: passwords).servers.isEmpty)
    }

    func testUnsavedPasswordsDoNotRequireKeychainAccess() throws {
        let passwords = MemorySSHPasswords()
        passwords.fails = true
        let store = SSHServerStore(defaults: defaults(), passwords: passwords)
        let server = try store.save(id: nil, name: "temporary", endpoint: endpoint(), password: "session-only", rememberPassword: false)
        XCTAssertNil(try store.password(for: server))
        try store.remove(server)
        XCTAssertTrue(store.servers.isEmpty)
    }

    func testKeychainFailureDoesNotCommitMetadataOrLoseTheFormDraft() throws {
        let defaults = defaults(), passwords = MemorySSHPasswords()
        let store = SSHServerStore(defaults: defaults, passwords: passwords)
        let server = try store.save(id: nil, name: "original", endpoint: endpoint(), password: "saved", rememberPassword: true)
        let form = SSHServerForm()
        form.address = "draft.example.com"; form.username = "draft"; form.password = "draft-password"
        passwords.fails = true
        XCTAssertThrowsError(try store.save(id: server.id, name: "changed", endpoint: endpoint(), password: "new", rememberPassword: true))
        XCTAssertThrowsError(try store.remove(server))
        XCTAssertThrowsError(try form.load(server, from: store))
        XCTAssertEqual(store.servers, [server])
        XCTAssertEqual(SSHServerStore(defaults: defaults, passwords: passwords).servers, [server])
        XCTAssertEqual(form.password, "draft-password")
        XCTAssertEqual(form.address, "draft.example.com")
    }

    func testSelectingSwitchesCredentialsAndChangingIdentityClearsLoadedPassword() throws {
        let store = SSHServerStore(defaults: defaults(), passwords: MemorySSHPasswords())
        let first = try store.save(id: nil, name: "first", endpoint: endpoint(), password: "first-password", rememberPassword: true)
        let second = try store.save(id: nil, name: "second", endpoint: endpoint("other.example.com"), password: "not-saved", rememberPassword: false)
        let form = SSHServerForm()
        try form.load(first, from: store)
        form.name = "rename"
        form.address = "ssh://alex@EXAMPLE.com:22"
        XCTAssertEqual(form.password, "first-password")
        form.address = "other.example.com"
        XCTAssertEqual(form.password, "")
        try form.load(first, from: store)
        form.username = "root"
        XCTAssertEqual(form.password, "")
        try form.load(first, from: store)
        try form.load(second, from: store)
        XCTAssertEqual(form.password, "")
        XCTAssertFalse(form.rememberPassword)
        form.reset()
        XCTAssertNil(form.serverID)
        XCTAssertTrue(form.address.isEmpty)
    }

    func testEditingEndpointReplacesCredentialAndKeepsProfileIdentity() throws {
        let passwords = MemorySSHPasswords()
        let store = SSHServerStore(defaults: defaults(), passwords: passwords)
        let original = try store.save(id: nil, name: "dev", endpoint: endpoint(), password: "old", rememberPassword: true)
        let form = SSHServerForm()
        try form.load(original, from: store)
        form.address = "new.example.com:2222"
        form.password = "new"
        let changed = try form.save(to: store)
        XCTAssertEqual(changed.id, original.id)
        XCTAssertEqual(changed.endpoint.host, "new.example.com")
        XCTAssertEqual(try store.password(for: changed), "new")
        XCTAssertEqual(store.servers.count, 1)
    }

    func testLegacyServerMigratesOnceWithoutResurrectingAfterDeletion() throws {
        let defaults = defaults(), passwords = MemorySSHPasswords()
        defaults.set("ssh://legacy@example.com:2222", forKey: "ssh.address")
        defaults.set("ignored", forKey: "ssh.user")
        let store = SSHServerStore(defaults: defaults, passwords: passwords)
        let server = try XCTUnwrap(store.servers.first)
        XCTAssertEqual(server.endpoint.username, "legacy")
        XCTAssertEqual(server.endpoint.port, 2222)
        XCTAssertFalse(server.remembersPassword)
        try store.remove(server)
        XCTAssertTrue(SSHServerStore(defaults: defaults, passwords: passwords).servers.isEmpty)
    }

    func testRealKeychainRoundTripUpdateAndDeletion() throws {
        let keychain = SSHKeychain(service: "com.ias.seto.tests." + UUID().uuidString)
        let id = UUID()
        defer { try? keychain.removePassword(for: id) }
        XCTAssertNil(try keychain.password(for: id))
        try keychain.setPassword("한글 🔐 password", for: id)
        XCTAssertEqual(try keychain.password(for: id), "한글 🔐 password")
        try keychain.setPassword("updated", for: id)
        XCTAssertEqual(try keychain.password(for: id), "updated")
        try keychain.removePassword(for: id)
        XCTAssertNil(try keychain.password(for: id))
        try keychain.removePassword(for: id)
    }
}
