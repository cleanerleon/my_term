import Foundation
import CryptoKit

public struct CredentialMigrationResult {
    public var sessions: [Session]
    public var created: Int
    public var issues: [String]
}

public enum CredentialMigration {
    public static func run(_ sessions: [Session], store: CredentialStore) throws -> CredentialMigrationResult {
        var profiles = try store.profiles()
        let resolver = WindAuthResolver()
        var output: [Session] = [], issues: [String] = [], created = 0
        for original in sessions {
            var session = original
            guard session.kind == "SSH", session.credentialProfileID == nil else { output.append(session); continue }
            do {
                let credential: WindCredential
                let source: String, label: String
                if let reference = session.windAuthentication, session.windAuthenticationEnabled != false {
                    credential = try resolver.load(reference)
                    (source, label) = try resolver.migrationIdentity(reference)
                } else if !session.username.isEmpty || !session.identityFile.isEmpty {
                    credential = WindCredential(username: session.username, password: nil, identityFile: session.identityFile.isEmpty ? nil : session.identityFile, passphrase: nil)
                    source = "legacy"; label = session.name + " 认证"
                } else { output.append(session); continue }
                let username = session.username.isEmpty ? credential.username : session.username
                let path = session.identityFile.isEmpty ? credential.identityFile ?? "" : try IdentityFile.resolve(session.identityFile)
                let password = username == credential.username ? credential.password : nil
                let passphrase = credential.identityFile == path ? credential.passphrase : nil
                let identity = source + "\0" + username + "\0" + path
                let sourceKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                let profile: AuthenticationProfile
                if let existing = profiles.first(where: { $0.sourceKey == sourceKey }) { profile = existing }
                else {
                    let managedPath = path.isEmpty ? "" : try store.importIdentity(path)
                    let method: AuthenticationMethod = managedPath.isEmpty ? (password != nil ? .password : .agent) : (password != nil ? .keyAndPassword : .privateKey)
                    let suffix = !managedPath.isEmpty && credential.identityFile != path ? " · 私钥" : ""
                    profile = AuthenticationProfile(name: label + suffix, username: username, method: method, identityFile: managedPath, sourceKey: sourceKey, hasPassword: password != nil, hasPassphrase: passphrase != nil)
                    try store.save(profile, secrets: CredentialSecrets(password: password, passphrase: passphrase))
                    profiles.append(profile); created += 1
                }
                session.credentialProfileID = profile.id
                session.username = ""; session.identityFile = ""; session.windAuthenticationEnabled = false
                output.append(session)
            } catch { issues.append("\(session.name)：\(error.localizedDescription)"); output.append(session) }
        }
        return CredentialMigrationResult(sessions: output, created: created, issues: issues)
    }
}
