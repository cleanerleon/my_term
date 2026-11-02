import Foundation
import Darwin

/// A private local socket supplies one saved response per prompt to SSH_ASKPASS.
/// Only a socket address/token enters the child environment; passwords never enter files or argv.
public final class AuthenticationBroker: @unchecked Sendable {
    private let directory: URL
    private let path: String
    private let token = UUID().uuidString + UUID().uuidString
    private let lock = NSLock()
    private var used = Set<String>()
    private var stopped = false
    private let bindings: [AuthBinding]
    private let approvedHostFingerprint: String?
    private let source: DispatchSourceRead
    public var environment: [String: String] { ["WINDNATIVE_AUTH_SOCKET": path, "WINDNATIVE_AUTH_TOKEN": token] }

    public init(bindings: [AuthBinding], approvedHostFingerprint: String? = nil) throws {
        self.bindings = bindings
        self.approvedHostFingerprint = approvedHostFingerprint
        directory = URL(fileURLWithPath: "/tmp/wn-auth-" + UUID().uuidString)
        path = directory.appendingPathComponent("socket").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: directory); throw WindError.invalid("无法创建本地 SSH 认证通道。") }
        var address = Self.address(path)
        let result = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, listen(fd, 8) == 0 else { Darwin.close(fd); try? FileManager.default.removeItem(at: directory); throw WindError.invalid("无法启动本地 SSH 认证通道。") }
        _ = chmod(path, 0o600)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "WindNative.Authentication", qos: .userInitiated))
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            guard let self else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid(),
                  let request = try? Self.read(client), request["token"] == self.token,
                  let prompt = request["prompt"] else { return }
            self.lock.lock()
            let trustedHost = self.approvedHostFingerprint.map { fingerprint in
                prompt.contains("yes/no") && prompt.components(separatedBy: .whitespacesAndNewlines).contains(where: { $0 == fingerprint || $0 == fingerprint + "." })
            } ?? false
            let secret = !self.stopped && !self.used.contains(prompt) ? (trustedHost ? "yes" : AuthBinding.secret(for: prompt, bindings: self.bindings)) : nil
            if secret != nil { self.used.insert(prompt) }
            self.lock.unlock()
            let response = secret.map { ["secret": $0] } ?? [:]
            try? Self.write(response, to: client)
        }
        let directory = directory
        source.setCancelHandler { Darwin.close(fd); try? FileManager.default.removeItem(at: directory) }
        source.resume()
    }
    public func stop() { lock.lock(); defer { lock.unlock() }; if !stopped { stopped = true; source.cancel() } }
    deinit { stop() }

    public static func savedResponse(prompt: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let path = environment["WINDNATIVE_AUTH_SOCKET"], path.utf8.count < 104, let token = environment["WINDNATIVE_AUTH_TOKEN"] else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { return nil }; defer { Darwin.close(fd) }
        var address = address(path)
        let result = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { return nil }
        do { try write(["token": token, "prompt": prompt], to: fd); return try read(fd)["secret"] } catch { return nil }
    }
    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, value) in path.utf8.prefix(bytes.count - 1).enumerated() { bytes[index] = value }
        }
        return address
    }
    private static func read(_ fd: Int32) throws -> [String: String] {
        var data = Data()
        while data.count <= 16_384 {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 5000) > 0 else { throw WindError.invalid("认证通道超时。") }
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 1 else { throw WindError.invalid("认证通道已关闭。") }
            if byte == 10 { return (try JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:] }
            data.append(byte)
        }
        throw WindError.invalid("认证响应过长。")
    }
    private static func write(_ object: [String: String], to fd: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        var noSignal: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                guard count > 0 else { throw WindError.invalid("认证通道写入失败。") }; offset += count
            }
        }
    }
}
