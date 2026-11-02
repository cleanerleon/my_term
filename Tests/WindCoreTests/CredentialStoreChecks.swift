import Foundation
import WindCore

func checkManagedCredentialVault() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = EphemeralVaultKey(), store = CredentialStore(directory: directory, keyProvider: EphemeralVaultKey())
    // Use one stable provider across reopen, as the production Keychain does across launches.
    let vault = CredentialStore(directory: directory, keyProvider: key)
    let profile = AuthenticationProfile(name: "Shared fixture", username: "fixture", method: .password)
    try vault.save(profile, secrets: CredentialSecrets(password: "synthetic-vault-password"))
    let encoded = try Data(contentsOf: vault.file)
    try expectFalse(String(decoding: encoded, as: UTF8.self).contains("synthetic-vault-password"))
    try expectFalse(String(decoding: encoded, as: UTF8.self).contains("Shared fixture"))
    let reopened = CredentialStore(directory: directory, keyProvider: key)
    try expectEqual(try reopened.credential(profile.id).1.password, "synthetic-vault-password")
    var target = Session(id: "managed-target", host: "server.invalid"); target.credentialProfileID = profile.id
    target.windAuthentication = WindAuthReference(sessionsFile: "/not-present/user.sessions", sessionID: target.id)
    let prepared = try WindAuthResolver().prepare(target, all: [target], store: reopened)
    try expectEqual(prepared.session.username, "fixture")
    try expectEqual(AuthBinding.secret(for: "fixture@server.invalid's password:", bindings: prepared.bindings), "synthetic-vault-password")
    var updated = profile; updated.username = "updated-user"
    try reopened.save(updated, secrets: CredentialSecrets(password: "updated-synthetic-password"))
    let next = try WindAuthResolver().prepare(target, all: [target], store: reopened)
    try expectEqual(next.session.username, "updated-user")
    try expectEqual(next.bindings.first?.password, "updated-synthetic-password")
    // A missing or wrong key must not replace an existing vault with an empty one.
    try expectThrows(try store.profiles())
    let beforeFailedSave = try Data(contentsOf: vault.file)
    try expectThrows(try store.save(profile, secrets: CredentialSecrets(password: "wrong-key-write")))
    try expectEqual(try Data(contentsOf: vault.file), beforeFailedSave)
    try reopened.delete(profile.id)
    try expectThrows(try WindAuthResolver().prepare(target, all: [target], store: reopened))
}

func checkCredentialMigrationIndependence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-migration-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = directory.appendingPathComponent("wind-profile"), terminal = profile.appendingPathComponent("terminal")
    try FileManager.default.createDirectory(at: terminal, withIntermediateDirectories: true)
    let fingerprint = "synthetic-migration"
    try JSONSerialization.data(withJSONObject: ["application.fingerprint": fingerprint, "application.masterPassword": false]).write(to: profile.appendingPathComponent("user.config"))
    let cipher = try fixtureEncryption(["session.user": "fixture", "Password": "synthetic-imported-password", "PasswordEnabled": true], fingerprint: fingerprint)
    try JSONSerialization.data(withJSONObject: [["uuid": "shared", "name": "Shared authentication", "auth": cipher]]).write(to: terminal.appendingPathComponent("onekeys.config"))
    let rows: [[String: Any]] = [
        ["session.uuid": "first", "session.protocol": "SSH", "session.target": "first.invalid", "session.oneKey": "shared"],
        ["session.uuid": "second", "session.protocol": "SSH", "session.target": "second.invalid", "session.oneKey": "shared"]
    ]
    let source = terminal.appendingPathComponent("user.sessions")
    let before = try JSONSerialization.data(withJSONObject: rows); try before.write(to: source)
    let imported = try WindImporter.load(source).sessions
    let key = EphemeralVaultKey(), vaultDirectory = directory.appendingPathComponent("managed")
    let store = CredentialStore(directory: vaultDirectory, keyProvider: key)
    let migrated = try CredentialMigration.run(imported, store: store)
    try expectTrue(migrated.issues.isEmpty); try expectEqual(migrated.created, 1)
    try expectEqual(migrated.sessions[0].credentialProfileID, migrated.sessions[1].credentialProfileID)
    try expectEqual(try Data(contentsOf: source), before)
    let profileID = migrated.sessions[0].credentialProfileID!
    let existing = try store.credential(profileID).0
    try store.save(existing, secrets: CredentialSecrets(password: "owned-updated-password"))
    let refreshed = try CredentialMigration.run(imported, store: store)
    try expectEqual(refreshed.created, 0)
    try expectEqual(try store.credential(profileID).1.password, "owned-updated-password")
    try FileManager.default.removeItem(at: profile)
    let reopened = CredentialStore(directory: vaultDirectory, keyProvider: key)
    let prepared = try WindAuthResolver().prepare(migrated.sessions[0], all: migrated.sessions, store: reopened)
    try expectEqual(prepared.session.username, "fixture")
    try expectEqual(prepared.bindings.first?.password, "owned-updated-password")
    let encodedSessions = try JSONEncoder().encode(migrated.sessions)
    try expectFalse(String(decoding: encodedSessions, as: UTF8.self).contains("owned-updated-password"))
}
