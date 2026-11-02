import Foundation
import Darwin

public struct RemoteEntry: Identifiable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var size: UInt64?
    public var modified: Date?
    public var permissions: UInt32?
    public var id: String { path }
    public var isDirectory: Bool { (permissions ?? 0) & 0xf000 == 0x4000 }
    public var isSymbolicLink: Bool { (permissions ?? 0) & 0xf000 == 0xa000 }
}

struct SFTPPacket {
    var bytes = Data()
    var offset = 0
    init(_ bytes: Data = Data()) { self.bytes = bytes }
    mutating func put(_ value: UInt8) { bytes.append(value) }
    mutating func put(_ value: UInt32) { var big = value.bigEndian; withUnsafeBytes(of: &big) { bytes.append(contentsOf: $0) } }
    mutating func put(_ value: UInt64) { var big = value.bigEndian; withUnsafeBytes(of: &big) { bytes.append(contentsOf: $0) } }
    mutating func put(_ data: Data) { put(UInt32(data.count)); bytes.append(data) }
    mutating func put(_ string: String) { put(Data(string.utf8)) }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= bytes.count - offset else { throw WindError.invalid("SFTP 响应数据不完整。") }
        defer { offset += count }; return bytes.subdata(in: offset..<(offset + count))
    }
    mutating func byte() throws -> UInt8 { try take(1)[0] }
    mutating func uint32() throws -> UInt32 { try take(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    mutating func uint64() throws -> UInt64 { try take(8).reduce(0) { ($0 << 8) | UInt64($1) } }
    mutating func data() throws -> Data { let length = try uint32(); return try take(Int(length)) }
    mutating func string() throws -> String {
        guard let string = String(data: try data(), encoding: .utf8) else { throw WindError.invalid("远端文件名不是有效的 UTF-8。") }; return string
    }
    mutating func attrs(name: String, path: String) throws -> RemoteEntry {
        let flags = try uint32()
        var entry = RemoteEntry(name: name, path: path)
        if flags & 1 != 0 { entry.size = try uint64() }
        if flags & 2 != 0 { _ = try uint32(); _ = try uint32() }
        if flags & 4 != 0 { entry.permissions = try uint32() }
        if flags & 8 != 0 { _ = try uint32(); entry.modified = Date(timeIntervalSince1970: Double(try uint32())) }
        if flags & 0x80000000 != 0 {
            let count = try uint32(); guard count <= 4096 else { throw WindError.invalid("SFTP 扩展属性过多。") }
            for _ in 0..<count { _ = try data(); _ = try data() }
        }
        return entry
    }
}

/// One encrypted SSH subsystem per browser. File names are binary SFTP strings, never shell commands.
final class SFTPTransport: @unchecked Sendable {
    let process = Process()
    let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var stopped = false
    private var diagnostic = Data()
    private var configuration: URL?
    private var authentication: AuthenticationBroker?

    func start(arguments: [String], configuration: URL?, askpass: String?, authentication: AuthenticationBroker? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }
        self.configuration = configuration
        self.authentication = authentication
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        if let authentication { environment.merge(authentication.environment) { _, new in new } }
        if let askpass { environment["SSH_ASKPASS"] = askpass; environment["SSH_ASKPASS_REQUIRE"] = "force"; environment["DISPLAY"] = "WindNative" }
        process.environment = environment
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.diagnostic.append(chunk)
            if self.diagnostic.count > 16384 { self.diagnostic = self.diagnostic.suffix(16384) }
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
    }
    func failure() -> WindError {
        lock.lock(); defer { lock.unlock() }
        let message = String(decoding: diagnostic, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return WindError.invalid(message.isEmpty ? "SFTP 连接已关闭，请重新连接。" : "SFTP：\(message)")
    }
    func write(_ packet: Data) throws {
        lock.lock(); let cancelled = stopped; lock.unlock()
        guard !cancelled else { throw CancellationError() }
        do { try input.fileHandleForWriting.write(contentsOf: packet) } catch { throw failure() }
    }
    func read(_ count: Int) throws -> Data {
        var data = Data()
        let deadline = Date().addingTimeInterval(120)
        while data.count < count {
            try Task.checkCancellation()
            lock.lock(); let cancelled = stopped; lock.unlock()
            guard !cancelled else { throw CancellationError() }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 250)
            if result < 0 { if errno == EINTR { continue }; throw failure() }
            if result == 0 { guard Date() < deadline else { throw WindError.invalid("SFTP 响应超时，请重连后重试。") }; continue }
            guard let chunk = try output.fileHandleForReading.read(upToCount: count - data.count), !chunk.isEmpty else { throw failure() }
            data.append(chunk)
        }
        return data
    }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        authentication?.stop(); authentication = nil
        let running = process.isRunning
        if running { process.terminate() }
        let configuration = configuration
        lock.unlock()
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        let process = process, output = output, errors = errors
        DispatchQueue.global(qos: .utility).async {
            if running { process.waitUntilExit() }
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            if let configuration { try? FileManager.default.removeItem(at: configuration) }
        }
    }
    deinit { stop() }
}

public actor SFTPClient {
    private nonisolated let transport = SFTPTransport()
    private var nextID: UInt32 = 0
    private var connected = false
    public init() {}
    public nonisolated func disconnect() { transport.stop() }

    public func connect(session: Session, all: [Session], directory: URL, askpass: String?, credentialStore: CredentialStore? = nil) throws -> String {
        let file = directory.appendingPathComponent(UUID().uuidString + ".sftp.conf")
        let prepared = try WindAuthResolver().prepare(session, all: all, store: credentialStore)
        var bindings = prepared.bindings
        let plan = try ConnectionBuilder.build(prepared.session, all: prepared.all, configPath: file.path, resolver: { session in
            let defaults = try OpenSSHDefaults.resolve(session)
            for index in bindings.indices where bindings[index].host == session.host { bindings[index].host = defaults.first("hostname") ?? session.host }
            return defaults
        })
        guard session.kind == "SSH", let config = plan.config, let alias = plan.arguments.last else { throw WindError.invalid("文件管理器仅支持 SSH 会话。") }
        try config.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        do { return try open(arguments: ["-F", file.path, "-o", "NumberOfPasswordPrompts=3", "-s", alias, "sftp"], configuration: file, askpass: askpass, authentication: bindings.isEmpty ? nil : AuthenticationBroker(bindings: bindings)) }
        catch { try? FileManager.default.removeItem(at: file); disconnect(); throw error }
    }

    /// Also used by the loopback integration fixture with its isolated host trust and temporary keys.
    public func open(arguments: [String], configuration: URL? = nil, askpass: String? = nil, authentication: AuthenticationBroker? = nil) throws -> String {
        guard !connected else { throw WindError.invalid("SFTP 已连接。") }
        try transport.start(arguments: arguments, configuration: configuration, askpass: askpass, authentication: authentication)
        var initPacket = SFTPPacket(); initPacket.put(UInt8(1)); initPacket.put(UInt32(3))
        try send(initPacket)
        var version = try receive()
        guard try version.byte() == 2, try version.uint32() == 3 else { throw WindError.invalid("服务器未提供 SFTP v3 协议。") }
        connected = true
        return try realpath(".")
    }
    private func send(_ payload: SFTPPacket) throws {
        var framed = SFTPPacket(); framed.put(UInt32(payload.bytes.count)); framed.bytes.append(payload.bytes)
        try transport.write(framed.bytes)
    }
    private func receive() throws -> SFTPPacket {
        var header = SFTPPacket(try transport.read(4)); let length = try header.uint32()
        guard length > 0 && length <= 16 * 1024 * 1024 else { throw WindError.invalid("SFTP 响应长度无效。") }
        return SFTPPacket(try transport.read(Int(length)))
    }
    private func request(_ type: UInt8, _ body: (inout SFTPPacket) -> Void) throws -> (UInt8, SFTPPacket) {
        try Task.checkCancellation()
        guard connected else { throw WindError.invalid("尚未连接 SFTP。") }
        nextID &+= 1
        var packet = SFTPPacket(); packet.put(type); packet.put(nextID); body(&packet)
        try send(packet)
        var response = try receive(); let type = try response.byte(); let id = try response.uint32()
        guard id == nextID else { throw WindError.invalid("SFTP 响应序号不匹配。") }
        return (type, response)
    }
    private func status(_ response: (UInt8, SFTPPacket), allowEOF: Bool = false) throws -> Bool {
        guard response.0 == 101 else { throw WindError.invalid("SFTP 服务器返回了意外响应。") }
        var body = response.1; let code = try body.uint32(); let message = try body.string()
        if code == 0 { return true }
        if allowEOF && code == 1 { return false }
        throw WindError.invalid("SFTP \(code)：\(message)")
    }
    private func handle(_ response: (UInt8, SFTPPacket)) throws -> Data {
        guard response.0 == 102 else { _ = try status(response); throw WindError.invalid("SFTP 未返回文件句柄。") }
        var body = response.1; return try body.data()
    }
    private func close(_ handle: Data) throws { _ = try status(request(4) { $0.put(handle) }) }
    public func realpath(_ path: String) throws -> String {
        let response = try request(16) { $0.put(path) }
        guard response.0 == 104 else { _ = try status(response); throw WindError.invalid("无法解析远程目录。") }
        var body = response.1
        guard try body.uint32() > 0 else { throw WindError.invalid("服务器未返回远程路径。") }
        return try body.string()
    }
    public func stat(_ path: String) throws -> RemoteEntry {
        let response = try request(17) { $0.put(path) }
        guard response.0 == 105 else { _ = try status(response); throw WindError.invalid("无法读取文件信息。") }
        var body = response.1
        return try body.attrs(name: (path as NSString).lastPathComponent, path: path)
    }
    public func list(_ path: String) throws -> [RemoteEntry] {
        let handle = try handle(request(11) { $0.put(path) })
        defer { try? close(handle) }
        var entries: [RemoteEntry] = []
        while true {
            let response = try request(12) { $0.put(handle) }
            if response.0 == 101 { _ = try status(response, allowEOF: true); break }
            guard response.0 == 104 else { throw WindError.invalid("无法读取远程目录。") }
            var body = response.1; let count = try body.uint32()
            guard count <= 100_000, entries.count + Int(count) <= 200_000 else { throw WindError.invalid("目录项过多，请进入子目录浏览。") }
            for _ in 0..<count {
                let name = try body.string(); _ = try body.string()
                let entry = try body.attrs(name: name, path: Self.join(path, name))
                // A server must not inject hierarchy into a directory entry.
                guard !name.contains("/"), !name.contains("\0") else { throw WindError.invalid("服务器返回了无效文件名。") }
                if name != "." && name != ".." { entries.append(entry) }
            }
        }
        return entries.sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    public static func join(_ parent: String, _ name: String) -> String { (parent == "/" ? "/" : parent + "/") + name }
    public func mkdir(_ path: String) throws { _ = try status(request(14) { $0.put(path); $0.put(UInt32(0)) }) }
    public func remove(_ path: String, directory: Bool = false) throws { _ = try status(request(directory ? 15 : 13) { $0.put(path) }) }
    public func rename(_ path: String, to destination: String) throws { _ = try status(request(18) { $0.put(path); $0.put(destination) }) }

    public func download(_ path: String, to destination: URL, progress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
        let info = try stat(path)
        guard !info.isDirectory else { throw WindError.invalid("请选择文件下载；暂不支持递归下载文件夹。") }
        let remote = try handle(request(3) { $0.put(path); $0.put(UInt32(1)); $0.put(UInt32(0)) })
        defer { try? close(remote) }
        // Commit only a complete download; existing destination content survives network failures.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".windnative-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw WindError.invalid("无法创建本地下载文件。") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let local = try FileHandle(forWritingTo: temporary); defer { try? local.close() }
        var offset: UInt64 = 0
        while true {
            let response = try request(5) { $0.put(remote); $0.put(offset); $0.put(UInt32(65536)) }
            if response.0 == 101 { _ = try status(response, allowEOF: true); break }
            guard response.0 == 103 else { throw WindError.invalid("下载响应无效。") }
            var body = response.1; let chunk = try body.data()
            guard !chunk.isEmpty else { throw WindError.invalid("下载返回空数据，已停止。") }
            try local.write(contentsOf: chunk); offset += UInt64(chunk.count); progress(offset, info.size ?? offset)
        }
        try local.synchronize(); try local.close()
        // POSIX rename atomically replaces only after the complete file is received.
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw WindError.invalid("无法保存下载文件：\(String(cString: strerror(errno)))") }
    }
    public func upload(_ source: URL, to path: String, progress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
        let info = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true else { throw WindError.invalid("请选择普通文件上传；暂不支持递归上传文件夹。") }
        let local = try FileHandle(forReadingFrom: source); defer { try? local.close() }
        let temporary = Self.join((path as NSString).deletingLastPathComponent, ".windnative-upload-" + UUID().uuidString)
        let remote = try handle(request(3) { $0.put(temporary); $0.put(UInt32(2 | 8 | 32)); $0.put(UInt32(0)) })
        var committed = false
        defer { if !committed { _ = try? status(request(13) { $0.put(temporary) }) } }
        var closed = false
        defer { if !closed { try? close(remote) } }
        var offset: UInt64 = 0
        while let chunk = try local.read(upToCount: 65536), !chunk.isEmpty {
            _ = try status(request(6) { $0.put(remote); $0.put(offset); $0.put(chunk) })
            offset += UInt64(chunk.count); progress(offset, UInt64(info.fileSize ?? 0))
        }
        try close(remote); closed = true
        try rename(temporary, to: path); committed = true
    }
}
