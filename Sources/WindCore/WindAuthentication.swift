import Foundation
import CommonCrypto
import CWindCrypto

public struct WindAuthReference: Codable, Equatable, Sendable {
    public var sessionsFile: String
    public var sessionID: String
    public init(sessionsFile: String, sessionID: String) { self.sessionsFile = sessionsFile; self.sessionID = sessionID }
}

public struct WindCredential: Sendable {
    public var username: String
    public var password: String?
    public var identityFile: String?
    public var passphrase: String?
}

public enum WindCrypto {
    public static func sha3(_ data: Data) -> Data {
        var output = [UInt8](repeating: 0, count: 64)
        data.withUnsafeBytes { bytes in wind_sha3_512(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &output) }
        return Data(output)
    }
    public static func derive(password: String, fingerprint: String, rounds: UInt32 = 100_000) -> Data {
        let password = Data(password.utf8), salt = Data(fingerprint.utf8)
        var output = [UInt8](repeating: 0, count: 48)
        password.withUnsafeBytes { p in salt.withUnsafeBytes { s in
            wind_pbkdf2_sha3_512(p.bindMemory(to: UInt8.self).baseAddress, password.count, s.bindMemory(to: UInt8.self).baseAddress, salt.count, rounds, &output)
        } }
        return Data(output)
    }
    public static func decrypt(_ base64: String, material: Data) throws -> Data {
        guard material.count == 48, let input = Data(base64Encoded: base64), !input.isEmpty, input.count % 16 == 0 else { throw WindError.invalid("WindTerm 认证数据格式无效。") }
        var output = Data(count: input.count + 16), count = 0
        let capacity = output.count, key = material.prefix(32), iv = material.suffix(16)
        let status = output.withUnsafeMutableBytes { out in input.withUnsafeBytes { source in key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key.baseAddress, 32, iv.baseAddress, source.baseAddress, input.count, out.baseAddress, capacity, &count)
        } } } }
        guard status == kCCSuccess else { throw WindError.invalid("WindTerm 认证信息解锁失败，请检查主密码或配置版本。") }
        output.count = count; return output
    }
}

/// A resolver lives only for a connection attempt; no cleartext password or derived key is written to disk.
public final class WindAuthResolver {
    private var materials: [String: Data] = [:]
    public init() {}
    public func load(_ reference: WindAuthReference) throws -> WindCredential {
        let file = URL(fileURLWithPath: reference.sessionsFile)
        let root = file.deletingLastPathComponent().deletingLastPathComponent()
        guard let config = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("user.config"))) as? [String: Any], let fingerprint = config["application.fingerprint"] as? String, !fingerprint.isEmpty else { throw WindError.invalid("WindTerm 配置缺少认证指纹。") }
        guard config["application.masterPassword"] as? Bool != true else { throw WindError.invalid("该 WindTerm 配置启用了主密码，当前未解锁。可先在连接设置中手动指定用户名和密钥。") }
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] ?? []
        guard let row = rows.first(where: { $0["session.uuid"] as? String == reference.sessionID }) else { throw WindError.invalid("WindTerm 中已找不到该会话的认证信息，请重新导入。") }
        let blob: String
        if let direct = row["session.autoLogin"] as? String, !direct.isEmpty { blob = direct }
        else if let id = row["session.oneKey"] as? String {
            let keys = try JSONSerialization.jsonObject(with: Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent("onekeys.config"))) as? [[String: Any]] ?? []
            guard let auth = keys.first(where: { $0["uuid"] as? String == id })?["auth"] as? String else { throw WindError.invalid("WindTerm 共享认证项不存在。") }
            blob = auth
        } else { throw WindError.invalid("该会话没有保存的 WindTerm 认证信息。") }
        let material: Data
        if let cached = materials[fingerprint] { material = cached }
        else { material = WindCrypto.derive(password: "", fingerprint: fingerprint); materials[fingerprint] = material }
        let clear = try WindCrypto.decrypt(blob, material: material)
        guard let object = try JSONSerialization.jsonObject(with: clear) as? [String: Any], let user = object["session.user"] as? String, !user.isEmpty else { throw WindError.invalid("解锁后的 WindTerm 认证结构不受支持。") }
        let publicKey = object["Public Key"] as? [String: Any] ?? [:]
        var keyPath: String?, passphrase: String?
        for platform in ["macos", "mac", "linux", "windows"] {
            guard let value = publicKey[platform + ".path"] as? String, !value.isEmpty else { continue }
            let expanded = (value as NSString).expandingTildeInPath
            if FileManager.default.isReadableFile(atPath: expanded) {
                keyPath = try IdentityFile.resolve(expanded); passphrase = publicKey[platform + ".pass"] as? String; break
            }
        }
        let password = object["PasswordEnabled"] as? Bool == true ? object["Password"] as? String : nil
        return WindCredential(username: user, password: password, identityFile: keyPath, passphrase: passphrase)
    }

    public func migrationIdentity(_ reference: WindAuthReference) throws -> (String, String) {
        let file = URL(fileURLWithPath: reference.sessionsFile)
        let root = file.deletingLastPathComponent().deletingLastPathComponent()
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("user.config"))) as? [String: Any] ?? [:]
        let fingerprint = config["application.fingerprint"] as? String ?? root.path
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] ?? []
        let row = rows.first { $0["session.uuid"] as? String == reference.sessionID } ?? [:]
        if let id = row["session.oneKey"] as? String, (row["session.autoLogin"] as? String ?? "").isEmpty {
            let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent("onekeys.config"))) as? [[String: Any]] ?? []
            let name = entries.first { $0["uuid"] as? String == id }?["name"] as? String ?? "WindTerm 共享认证"
            return (fingerprint + ":shared:" + id, name)
        }
        return (fingerprint + ":session:" + reference.sessionID, (row["session.label"] as? String ?? "WindTerm") + " 认证")
    }
    public func prepare(_ target: Session, all: [Session], store: CredentialStore? = nil) throws -> PreparedAuthentication {
        if target.kind == "SSH" { _ = try JumpSettings.chain(target, all: all) }
        var sessions = all, bindings: [AuthBinding] = [], active = Set<String>(), done = Set<String>()
        if !sessions.contains(where: { $0.id == target.id }) { sessions.append(target) }
        // The caller may have unsaved edits or be reconnecting a terminal snapshot.
        if let index = sessions.firstIndex(where: { $0.id == target.id }) { sessions[index] = target }
        func resolve(_ id: String) throws {
            guard !active.contains(id) else { throw WindError.invalid("跳板机形成循环。") }
            guard !done.contains(id), let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            active.insert(id)
            var session = sessions[index]
            var resolvedCredential: WindCredential?
            if let id = session.credentialProfileID {
                guard let store else { throw WindError.invalid("无法读取程序管理的认证配置。") }
                let (profile, secrets) = try store.credential(id)
                resolvedCredential = WindCredential(username: profile.username, password: profile.method.usesPassword ? secrets.password : nil, identityFile: profile.method.usesKey ? profile.identityFile : nil, passphrase: profile.method.usesKey ? secrets.passphrase : nil)
            } else if let reference = session.windAuthentication, session.windAuthenticationEnabled != false {
                resolvedCredential = try load(reference)
            }
            if let credential = resolvedCredential {
                if session.username.isEmpty { session.username = credential.username }
                if session.identityFile.isEmpty, let path = credential.identityFile { session.identityFile = path }
                if !session.identityFile.isEmpty { session.identityFile = try IdentityFile.resolve(session.identityFile) }
                bindings.append(AuthBinding(host: session.host, username: session.username, identityFile: session.identityFile, password: session.username == credential.username ? credential.password : nil, passphrase: credential.identityFile.map { ($0 as NSString).standardizingPath == (session.identityFile as NSString).expandingTildeInPath } == true ? credential.passphrase : nil))
                sessions[index] = session
            }
            if session.effectiveJumpMode(all: sessions) == .session {
                guard let jump = sessions.first(where: { $0.id == session.jump }) else { throw WindError.invalid("跳板机会话已不存在，请重新选择。") }
                try resolve(jump.id)
            }
            active.remove(id); done.insert(id)
        }
        try resolve(target.id)
        return PreparedAuthentication(session: sessions.first { $0.id == target.id }!, all: sessions, bindings: bindings)
    }
}

public struct PreparedAuthentication {
    public var session: Session
    public var all: [Session]
    public var bindings: [AuthBinding]
}

public struct AuthBinding: Sendable {
    public var host: String
    public var username: String
    public var identityFile: String
    public var password: String?
    public var passphrase: String?
    public init(host: String, username: String, identityFile: String, password: String? = nil, passphrase: String? = nil) {
        self.host = host; self.username = username; self.identityFile = identityFile; self.password = password; self.passphrase = passphrase
    }
    public static func secret(for prompt: String, bindings: [AuthBinding]) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = bindings.compactMap { binding -> String? in
            if trimmed == "\(binding.username)@\(binding.host)'s password:" { return binding.password }
            let path = (binding.identityFile as NSString).expandingTildeInPath
            if !path.isEmpty && trimmed == "Enter passphrase for key '\(path)':" { return binding.passphrase }
            return nil
        }
        let unique = Set(matches)
        return unique.count == 1 ? unique.first : nil
    }
}
