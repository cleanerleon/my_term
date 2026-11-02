import Foundation
import CryptoKit
import Security

public enum AuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case password, privateKey, keyAndPassword, agent
    public var title: String {
        switch self { case .password: return "密码"; case .privateKey: return "私钥"; case .keyAndPassword: return "私钥 + 密码"; case .agent: return "SSH Agent" }
    }
    public var usesPassword: Bool { self == .password || self == .keyAndPassword }
    public var usesKey: Bool { self == .privateKey || self == .keyAndPassword }
}

public struct AuthenticationProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var username: String
    public var method: AuthenticationMethod
    public var identityFile: String
    public var sourceKey: String?
    public var hasPassword: Bool
    public var hasPassphrase: Bool
    public init(id: String = UUID().uuidString, name: String = "新认证配置", username: String = "", method: AuthenticationMethod = .agent, identityFile: String = "", sourceKey: String? = nil, hasPassword: Bool = false, hasPassphrase: Bool = false) {
        self.id = id; self.name = name; self.username = username; self.method = method; self.identityFile = identityFile; self.sourceKey = sourceKey; self.hasPassword = hasPassword; self.hasPassphrase = hasPassphrase
    }
}

public struct CredentialSecrets: Codable, Sendable {
    public var password: String?
    public var passphrase: String?
    public init(password: String? = nil, passphrase: String? = nil) { self.password = password; self.passphrase = passphrase }
}
public protocol VaultKeyProvider: Sendable { func key(createIfMissing: Bool) throws -> Data }

public final class KeychainVaultKey: VaultKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var cached: Data?
    public init() {}
    public func key(createIfMissing: Bool) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.windnative.credential-vault", kSecAttrAccount as String: "vault-key"]
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { cached = data; return data }
        guard status == errSecItemNotFound && createIfMissing else { throw WindError.invalid("无法读取 MyTerm 钥匙串密钥（\(status)）。请允许钥匙串访问后重试，原认证库未被改写。") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WindError.invalid("无法生成认证库密钥。") }
        let data = Data(bytes)
        var record = query; record[kSecValueData as String] = data
        record[kSecAttrLabel as String] = "MyTerm 认证库"
        record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(record as CFDictionary, nil)
        guard result == errSecSuccess else { throw WindError.invalid("无法创建 MyTerm 钥匙串密钥（\(result)）。") }
        cached = data; return data
    }
}

/// Tests and isolated UI fixtures use a nonpersistent key and never touch the user's Keychain.
public final class EphemeralVaultKey: VaultKeyProvider, @unchecked Sendable {
    private let value = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    public init() {}
    public func key(createIfMissing: Bool) throws -> Data { value }
}

public final class CredentialStore: @unchecked Sendable {
    private struct Record: Codable { var profile: AuthenticationProfile; var secrets: CredentialSecrets }
    private struct Envelope: Codable { var version = 1; var sealed: Data }
    public let file: URL
    public let keysDirectory: URL
    private let keyProvider: any VaultKeyProvider
    private let lock = NSRecursiveLock()
    private var records: [String: Record] = [:]
    private var loaded = false
    public init(directory: URL, keyProvider: any VaultKeyProvider = KeychainVaultKey()) {
        file = directory.appendingPathComponent("credentials.vault")
        keysDirectory = directory.appendingPathComponent("Keys")
        self.keyProvider = keyProvider
    }
    public func load() throws {
        lock.lock(); defer { lock.unlock() }
        if loaded { return }
        guard FileManager.default.fileExists(atPath: file.path) else { loaded = true; return }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
        guard envelope.version == 1 else { throw WindError.invalid("认证库版本不受支持，原文件未被改写。") }
        let key = SymmetricKey(data: try keyProvider.key(createIfMissing: false))
        do { records = try JSONDecoder().decode([String: Record].self, from: AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key)) }
        catch { throw WindError.invalid("认证库解锁失败，原文件未被改写。请检查钥匙串或恢复匹配的备份。") }
        loaded = true
    }
    public func profiles() throws -> [AuthenticationProfile] {
        lock.lock(); defer { lock.unlock() }; try load()
        return records.values.map(\.profile).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func credential(_ id: String) throws -> (AuthenticationProfile, CredentialSecrets) {
        lock.lock(); defer { lock.unlock() }; try load()
        guard let record = records[id] else { throw WindError.invalid("关联的认证配置不存在，请重新选择认证配置。") }
        return (record.profile, record.secrets)
    }
    public func save(_ profile: AuthenticationProfile, secrets: CredentialSecrets) throws {
        lock.lock(); defer { lock.unlock() }; try load()
        var profile = profile
        profile.hasPassword = secrets.password != nil; profile.hasPassphrase = secrets.passphrase != nil
        var updated = records; updated[profile.id] = Record(profile: profile, secrets: secrets)
        try commit(updated); records = updated
    }
    public func delete(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }; try load()
        let removed = records[id]
        var updated = records; updated.removeValue(forKey: id)
        try commit(updated); records = updated
        if let path = removed?.profile.identityFile, isManagedKey(path), !records.values.contains(where: { $0.profile.identityFile == path }) { try? FileManager.default.removeItem(atPath: path) }
    }
    private func commit(_ updated: [String: Record]) throws {
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = SymmetricKey(data: try keyProvider.key(createIfMissing: !FileManager.default.fileExists(atPath: file.path)))
        let sealed = try AES.GCM.seal(JSONEncoder().encode(updated), using: key)
        guard let combined = sealed.combined else { throw WindError.invalid("无法加密认证配置。") }
        try JSONEncoder().encode(Envelope(sealed: combined)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func isManagedKey(_ path: String) -> Bool { URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL == keysDirectory.standardizedFileURL }
    public func importIdentity(_ value: String) throws -> String {
        let path = try IdentityFile.resolve(value)
        if isManagedKey(path), FileManager.default.isReadableFile(atPath: path) { return path }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw WindError.invalid("请选择有效的 SSH 私钥文件。") }
        let bytes = try Data(contentsOf: url)
        let header = String(decoding: bytes.prefix(100), as: UTF8.self)
        guard header.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") || header.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") || header.hasPrefix("-----BEGIN EC PRIVATE KEY-----") || header.hasPrefix("-----BEGIN PRIVATE KEY-----") || header.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----") else { throw WindError.invalid("文件不是支持的 SSH 私钥。") }
        try FileManager.default.createDirectory(at: keysDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let hash = SHA256.hash(data: bytes).prefix(12).map { String(format: "%02x", $0) }.joined()
        let destination = keysDirectory.appendingPathComponent(hash + "-" + url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destination.path) { try bytes.write(to: destination, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination.path
    }
}
