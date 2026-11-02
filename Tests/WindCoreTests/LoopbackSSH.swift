import Foundation
import Darwin
import WindCore

private func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15, environment: [String: String]? = nil) throws -> (Int32, String) {
    let task = Process(); let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
    if let environment { task.environment = environment }
    task.standardOutput = pipe; task.standardError = pipe
    try task.run()
    let cancellation = DispatchWorkItem { if task.isRunning { task.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: cancellation)
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit(); cancellation.cancel()
    return (task.terminationStatus, String(decoding: data, as: UTF8.self))
}
private func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CheckSkip("无法创建本地测试 socket") }
    defer { close(fd) }
    var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard bound == 0 else { throw CheckSkip("无法绑定回环测试端口") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    return Int(UInt16(bigEndian: address.sin_port))
}

func checkLoopbackSSH() throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") else { throw CheckSkip("未安装 sshd") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("windnative-ssh-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = directory.appendingPathComponent("identity").path
    let jumpKey = directory.appendingPathComponent("jump-identity").path
    let hostKey = directory.appendingPathComponent("host").path
    for file in [key, jumpKey, hostKey] {
        let result = try command("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", file])
        try expectEqual(result.0, 0, "生成临时测试密钥失败")
    }
    let port = try freePort(), jumpPort = try freePort()
    let serverConfig = directory.appendingPathComponent("sshd_config")
    let text = """
    ListenAddress 127.0.0.1
    Port \(port)
    Port \(jumpPort)
    HostKey \(hostKey)
    PidFile \(directory.path)/sshd.pid
    AuthorizedKeysFile \(key).pub
    StrictModes no
    UsePAM no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    PermitRootLogin no
    AllowUsers \(NSUserName())
    AllowTcpForwarding yes
    Subsystem sftp internal-sftp
    LogLevel ERROR
    Match LocalPort \(jumpPort)
      AuthorizedKeysFile \(jumpKey).pub
    """
    try text.write(to: serverConfig, atomically: true, encoding: .utf8)
    let server = Process(); let errors = Pipe()
    server.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
    server.arguments = ["-D", "-e", "-f", serverConfig.path]
    server.standardError = errors; server.standardOutput = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
    var ready = false
    for _ in 0..<20 {
        if !server.isRunning { break }
        if try command("/usr/bin/nc", ["-z", "-w", "1", "127.0.0.1", String(port)], timeout: 2).0 == 0 { ready = true; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard ready else {
        if server.isRunning { server.terminate(); server.waitUntilExit() }
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw CheckSkip("本机不允许启动独立 sshd：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    let hostPublic = try String(contentsOfFile: hostKey + ".pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
    let known = directory.appendingPathComponent("known_hosts")
    try "[127.0.0.1]:\(port) \(hostPublic)\n[127.0.0.1]:\(jumpPort) \(hostPublic)\n".write(to: known, atomically: true, encoding: .utf8)
    let jump = Session(id: "fixture-jump", host: "127.0.0.1", port: jumpPort, username: NSUserName(), identityFile: jumpKey)
    let target = Session(id: "fixture-target", host: "127.0.0.1", port: port, username: NSUserName(), identityFile: key, jump: jump.id)
    // Replicate the production regression: OpenSSH ProxyJump invokes a child
    // through the shell, which splits an unquoted -F path containing spaces.
    let spaceDir = directory.appendingPathComponent("Application Support")
    try FileManager.default.createDirectory(at: spaceDir, withIntermediateDirectories: true)
    let unsafeConfig = spaceDir.appendingPathComponent("client_config")
    let unsafePlan = try ConnectionBuilder.build(target, all: [target, jump], configPath: unsafeConfig.path)
    let trustHeader = "Host *\n  UserKnownHostsFile \"\(known.path)\"\n  StrictHostKeyChecking yes\n  BatchMode yes\n  IdentitiesOnly yes\n\n"
    try (trustHeader + unsafePlan.config!).write(to: unsafeConfig, atomically: true, encoding: .utf8)
    let broken = try command(unsafePlan.executable, unsafePlan.arguments + ["true"], timeout: 15)
    try expectEqual(broken.0, 255)
    try expectTrue(broken.1.contains("Can't open user config file"))
    let runtime = ConnectionRuntime.newDirectoryURL()
    try ConnectionRuntime.create(runtime)
    defer { try? FileManager.default.removeItem(at: runtime) }
    let mode = try FileManager.default.attributesOfItem(atPath: runtime.path)[.posixPermissions] as? NSNumber
    try expectEqual(mode?.intValue, 0o700)
    let clientConfig = runtime.appendingPathComponent("client_config")
    let plan = try ConnectionBuilder.build(target, all: [target, jump], configPath: clientConfig.path)
    // Only ephemeral test hosts are pretrusted; production behavior remains ask.
    let config = "Host *\n  UserKnownHostsFile \"\(known.path)\"\n  StrictHostKeyChecking yes\n  BatchMode yes\n  IdentitiesOnly yes\n\n" + plan.config!
    try config.write(to: clientConfig, atomically: true, encoding: .utf8)
    let connected = try command(plan.executable, plan.arguments + ["printf WINDNATIVE_JUMP_OK"], timeout: 15)
    try expectEqual(connected.0, 0, connected.1)
    try expectTrue(connected.1.contains("WINDNATIVE_JUMP_OK"), "真实 SSH 跳板测试未收到远端输出")
    // Reproduce a changed target key through a working bastion, then remove only
    // the confirmed offending record. No real user's known_hosts is touched.
    let originalKnown = try Data(contentsOf: known)
    let wrongPublic = try String(contentsOfFile: jumpKey + ".pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
    try "[127.0.0.1]:\(port) \(wrongPublic)\n[127.0.0.1]:\(jumpPort) \(hostPublic)\n".write(to: known, atomically: true, encoding: .utf8)
    try expectEqual(try command("/usr/bin/ssh-keygen", ["-H", "-f", known.path]).0, 0)
    let changed = try command(plan.executable, plan.arguments + ["true"])
    try expectEqual(changed.0, 255)
    let change = try unwrap(HostKeyChange.parse(changed.1))
    try expectEqual(change.host, "[127.0.0.1]:\(port)")
    let oldKnown = try Data(contentsOf: known)
    let backup = try change.removeOldKey(expectedContents: oldKnown)
    try expectEqual(try Data(contentsOf: backup), oldKnown)
    try expectEqual(try command("/usr/bin/ssh-keygen", ["-F", "[127.0.0.1]:\(jumpPort)", "-f", known.path]).0, 0)
    try expectEqual(try command("/usr/bin/ssh-keygen", ["-F", "[127.0.0.1]:\(port)", "-f", known.path]).0, 1)
    try expectThrows(try change.removeOldKey(expectedContents: oldKnown))
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("WindAskpass")
    try expectTrue(FileManager.default.isExecutableFile(atPath: helper.path))
    let approval = try AuthenticationBroker(bindings: [], approvedHostFingerprint: change.fingerprint)
    defer { approval.stop() }
    var environment = ProcessInfo.processInfo.environment
    environment.merge(approval.environment) { _, new in new }
    environment["SSH_ASKPASS"] = helper.path; environment["SSH_ASKPASS_REQUIRE"] = "force"; environment["DISPLAY"] = "WindNative"
    let reconnected = try command(plan.executable, ["-o", "StrictHostKeyChecking=ask", "-o", "BatchMode=no"] + plan.arguments + ["printf HOST_KEY_UPDATED"], environment: environment)
    try expectEqual(reconnected.0, 0, reconnected.1)
    try expectTrue(reconnected.1.contains("HOST_KEY_UPDATED"))
    try expectEqual(try command("/usr/bin/ssh-keygen", ["-F", "[127.0.0.1]:\(port)", "-f", known.path]).0, 0)
    try originalKnown.write(to: known, options: .atomic)
    // SFTP uses the exact same route and per-hop identities, tested without remote file changes.
    let batch = directory.appendingPathComponent("batch")
    try "pwd\nquit\n".write(to: batch, atomically: true, encoding: .utf8)
    let transfer = try command("/usr/bin/sftp", ["-F", clientConfig.path, "-b", batch.path, plan.arguments.last!])
    try expectEqual(transfer.0, 0, transfer.1)
    try expectTrue(transfer.1.contains("Remote working directory"))
    // Two saved bastions, each with its own config block, precede the target.
    var nestedTarget = target; nestedTarget.id = "nested-target"; nestedTarget.jump = "second-bastion"; nestedTarget.jumpMode = .session
    let secondHop = Session(id: "second-bastion", host: "127.0.0.1", port: jumpPort, username: NSUserName(), identityFile: jumpKey, jump: jump.id)
    let nestedConfig = runtime.appendingPathComponent("nested-config")
    let nestedPlan = try ConnectionBuilder.build(nestedTarget, all: [jump, secondHop, nestedTarget], configPath: nestedConfig.path)
    let nestedTrust = "Host *\n  UserKnownHostsFile \"\(known.path)\"\n  StrictHostKeyChecking yes\n  BatchMode yes\n  IdentitiesOnly yes\n\n"
    try (nestedTrust + nestedPlan.config!).write(to: nestedConfig, atomically: true, encoding: .utf8)
    let nestedSSH = try command(nestedPlan.executable, nestedPlan.arguments + ["printf NESTED_JUMP_OK"])
    try expectEqual(nestedSSH.0, 0, nestedSSH.1)
    try expectTrue(nestedSSH.1.contains("NESTED_JUMP_OK"))
    let nestedSFTP = try command("/usr/bin/sftp", ["-F", nestedConfig.path, "-b", batch.path, nestedPlan.arguments.last!])
    try expectEqual(nestedSFTP.0, 0, nestedSFTP.1)
    // Exercise the GUI browser's binary SFTP implementation through the same real jump.
    let fixtureRoot = directory.appendingPathComponent("remote-fixture")
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: fixtureRoot.appendingPathComponent("directory-link"), withDestinationURL: directory)
    let source = directory.appendingPathComponent("source.bin")
    let contents = Data((0..<210_123).map { UInt8($0 % 251) })
    try contents.write(to: source)
    let downloaded = directory.appendingPathComponent("download.bin")
    let arguments = ["-F", clientConfig.path, "-s", plan.arguments.last!, "sftp"]
    try runAsync {
        let client = SFTPClient()
        defer { client.disconnect() }
        _ = try await client.open(arguments: arguments)
        let canonical = try await client.realpath(fixtureRoot.path)
        let folder = SFTPClient.join(canonical, "中文 folder")
        try await client.mkdir(folder)
        var rows = try await client.list(canonical)
        try expectTrue(rows.contains { $0.name == "中文 folder" && $0.isDirectory })
        try expectTrue(rows.contains { $0.name == "directory-link" && $0.isSymbolicLink })
        let linkInfo = try await client.stat(SFTPClient.join(canonical, "directory-link"))
        try expectTrue(linkInfo.isDirectory)
        let name = "中文 ' \" $;[literal].bin"
        let destination = SFTPClient.join(folder, name)
        try await client.upload(source, to: destination)
        let info = try await client.stat(destination)
        try expectEqual(info.size, UInt64(contents.count))
        try await client.download(destination, to: downloaded)
        try expectEqual(try Data(contentsOf: downloaded), contents)
        var collisionRejected = false
        do { try await client.upload(source, to: destination) } catch { collisionRejected = true }
        try expectTrue(collisionRejected, "同名上传必须保留现有远端文件")
        rows = try await client.list(folder)
        try expectEqual(rows.map(\.name), [name])
        try await client.rename(destination, to: SFTPClient.join(folder, "renamed.bin"))
        rows = try await client.list(folder)
        try expectEqual(rows.map(\.name), ["renamed.bin"])
        let missing = SFTPClient.join(folder, "missing")
        var missingRejected = false
        do { try await client.download(missing, to: downloaded) } catch { missingRejected = true }
        try expectTrue(missingRejected)
        try expectEqual(try Data(contentsOf: downloaded), contents)
        try await client.remove(SFTPClient.join(folder, "renamed.bin"))
        try await client.remove(folder, directory: true)
        rows = try await client.list(canonical)
        try expectFalse(rows.contains { $0.name == "中文 folder" })
        client.disconnect()
        var cancelled = false
        do { _ = try await client.list(canonical) } catch { cancelled = true }
        try expectTrue(cancelled)
    }

    // A WindTerm-format encrypted shared profile supplies both username and key path.
    let profile = directory.appendingPathComponent("profile")
    let terminal = profile.appendingPathComponent("terminal")
    try FileManager.default.createDirectory(at: terminal, withIntermediateDirectories: true)
    let fingerprint = "isolated-auth-fixture"
    try JSONSerialization.data(withJSONObject: ["application.fingerprint": fingerprint, "application.masterPassword": false]).write(to: profile.appendingPathComponent("user.config"))
    let cipher = try fixtureEncryption(["session.user": NSUserName(), "PasswordEnabled": false, "Public Key": ["linux.path": key + ".pub", "linux.pass": ""], "uuidSalt": "fixture"], fingerprint: fingerprint)
    try JSONSerialization.data(withJSONObject: [["uuid": "fixture-auth", "auth": cipher, "name": "Fixture credential"]]).write(to: terminal.appendingPathComponent("onekeys.config"))
    let windRows: [[String: Any]] = [
        ["session.uuid": "fixture-jump", "session.label": "Bastion", "session.protocol": "SSH", "session.group": "Jump servers", "session.target": "127.0.0.1", "session.port": jumpPort, "session.oneKey": "fixture-auth", "ssh.identityFilePath.macos": jumpKey],
        ["session.uuid": "fixture-target", "session.label": "Local integration server", "session.protocol": "SSH", "session.group": "dev", "session.target": "127.0.0.1", "session.port": port, "session.oneKey": "fixture-auth", "session.proxy": "fixture-jump"]
    ]
    let windFile = terminal.appendingPathComponent("user.sessions")
    try JSONSerialization.data(withJSONObject: windRows).write(to: windFile)
    let windImported = try WindImporter.load(windFile).sessions
    let prepared = try WindAuthResolver().prepare(windImported[1], all: windImported)
    try expectEqual(prepared.session.username, NSUserName())
    try expectEqual(prepared.session.identityFile, key)
    let mismatch = directory.appendingPathComponent("mismatched-key").path
    try FileManager.default.copyItem(atPath: key, toPath: mismatch)
    try FileManager.default.copyItem(atPath: hostKey + ".pub", toPath: mismatch + ".pub")
    try expectThrows(try IdentityFile.resolve(mismatch + ".pub"))
    let authConfig = directory.appendingPathComponent("wind-auth-config")
    let authenticatedPlan = try ConnectionBuilder.build(prepared.session, all: prepared.all, configPath: authConfig.path)
    let trust = "Host *\n  UserKnownHostsFile \"\(known.path)\"\n  StrictHostKeyChecking yes\n  BatchMode yes\n\n"
    try (trust + authenticatedPlan.config!).write(to: authConfig, atomically: true, encoding: .utf8)
    let authResult = try command(authenticatedPlan.executable, authenticatedPlan.arguments + ["printf WIND_AUTH_OK"])
    try expectEqual(authResult.0, 0, authResult.1)
    try expectTrue(authResult.1.contains("WIND_AUTH_OK"))

    if let app = ProcessInfo.processInfo.environment["WINDNATIVE_TEST_APP"] {
        for name in ["autotest", "backup", "download", "scripts", "中文目录"] {
            try FileManager.default.createDirectory(at: fixtureRoot.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("SFTP browser fixture".utf8).write(to: fixtureRoot.appendingPathComponent("README.txt"))
        let sessionsFile = windFile
        let fixtures: [[String: Any]] = windRows + [
            ["session.uuid": "fixture-shell", "session.label": "zsh", "session.protocol": "Shell", "session.group": "Shell sessions", "session.target": "/bin/zsh"],
            ["session.uuid": "fixture-example", "session.label": "Production", "session.protocol": "SSH", "session.group": "vps", "session.target": "example.invalid"]
        ]
        try JSONSerialization.data(withJSONObject: fixtures).write(to: sessionsFile)
        let previewDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WINDNATIVE_PREVIEW_DIR"] ?? directory.path)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        let report = previewDirectory.appendingPathComponent("workspace-report.json")
        let application = Process(); application.executableURL = URL(fileURLWithPath: app)
        application.arguments = ["--smoke-report", report.path]
        var environment = ProcessInfo.processInfo.environment
        environment["WINDNATIVE_SMOKE_SESSIONS"] = sessionsFile.path
        environment["WINDNATIVE_SMOKE_SFTP_CONFIG"] = clientConfig.path
        environment["WINDNATIVE_SMOKE_SFTP_ALIAS"] = plan.arguments.last!
        environment["WINDNATIVE_SMOKE_REMOTE_PATH"] = fixtureRoot.path
        application.environment = environment
        application.standardOutput = FileHandle.nullDevice; application.standardError = FileHandle.nullDevice
        try application.run()
        let timeout = DispatchWorkItem { if application.isRunning { application.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: timeout)
        application.waitUntilExit(); timeout.cancel()
        try expectEqual(application.terminationStatus, 0, "应用级 SFTP 检查未正常退出")
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as! [String: Any]
        try expectTrue(result["passed"] as? Bool == true, "窗口、文件夹树或图形 SFTP 集成检查失败：\(result)")
    }

    // Migrated keys and credentials keep working after the WindTerm profile and original
    // private key disappear. The fixture server retains only its authorized public key.
    let managedDirectory = directory.appendingPathComponent("owned-credentials")
    let store = CredentialStore(directory: managedDirectory, keyProvider: EphemeralVaultKey())
    let migration = try CredentialMigration.run(windImported, store: store)
    try expectTrue(migration.issues.isEmpty)
    try expectEqual(migration.created, 2)
    try FileManager.default.removeItem(at: profile)
    try FileManager.default.removeItem(atPath: key)
    try FileManager.default.removeItem(atPath: jumpKey)
    let managed = try WindAuthResolver().prepare(migration.sessions[1], all: migration.sessions, store: store)
    try expectTrue(store.isManagedKey(managed.session.identityFile))
    let managedConfig = directory.appendingPathComponent("managed-config")
    let managedPlan = try ConnectionBuilder.build(managed.session, all: managed.all, configPath: managedConfig.path)
    try (trust + managedPlan.config!).write(to: managedConfig, atomically: true, encoding: .utf8)
    let managedConnection = try command(managedPlan.executable, managedPlan.arguments + ["printf MANAGED_KEY_OK"])
    try expectEqual(managedConnection.0, 0, managedConnection.1)
    try expectTrue(managedConnection.1.contains("MANAGED_KEY_OK"))
    let managedSFTP = ["-F", managedConfig.path, "-b", batch.path, managedPlan.arguments.last!]
    let managedTransfer = try command("/usr/bin/sftp", managedSFTP)
    try expectEqual(managedTransfer.0, 0, managedTransfer.1)

}
