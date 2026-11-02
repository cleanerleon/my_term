import Foundation
import AppKit
import SwiftTerm
import WindCore

final class WindCoreTests {
    func imported(_ rows: [[String: Any]]) throws -> [Session] {
        try WindImporter.parse(JSONSerialization.data(withJSONObject: rows)).sessions
    }
    func testImportsWindTermFieldsWithoutCredentials() throws {
        let sessions = try imported([[
            "session.uuid": "fixture", "session.label": "Production", "session.target": "alice@example.invalid",
            "session.group": "Servers", "session.protocol": "SSH", "session.port": "2222",
            "session.oneKey": "opaque-credential-reference", "ssh.verifyServerFingerprint": false
        ]])
        let s = try unwrap(sessions.first)
        try expectEqual(s.username, "alice"); try expectEqual(s.host, "example.invalid"); try expectEqual(s.port, 2222)
        try expectEqual(s.group, "Servers"); try expectEqual(s.warnings.count, 1)
        let encoded = String(data: try JSONEncoder().encode(s), encoding: .utf8)!
        try expectFalse(encoded.contains("opaque-credential-reference"))
        let plan = try ConnectionBuilder.build(s, all: sessions, configPath: "/tmp/config")
        try expectTrue(plan.config!.contains("StrictHostKeyChecking ask"))
        try expectFalse(plan.config!.contains("StrictHostKeyChecking no"))
    }
    func testInvalidRootAndDuplicateIDAreRejected() throws {
        try expectThrows(try WindImporter.parse(Data("{}".utf8)))
        try expectThrows(try imported([["session.uuid": "same"], ["session.uuid": "same"]]))
    }
    func testShellArgumentsAreParsedWithoutExpansion() throws {
        try expectEqual(try WindImporter.splitArguments("-l -c 'printf \"hello world\"'"), ["-l", "-c", "printf \"hello world\""])
        try expectEqual(try WindImporter.splitArguments("'' foo\\ bar \"$(whoami)\""), ["", "foo bar", "$(whoami)"])
        try expectThrows(try WindImporter.splitArguments("'unterminated"))
    }
    func testProxyUUIDResolvesToSeparateIdentityAndPort() throws {
        let sessions = try imported([
            ["session.uuid": "bastion", "session.protocol": "SSH", "session.target": "jump.invalid", "session.port": 2200, "ssh.userName": "gateway"],
            ["session.uuid": "target", "session.protocol": "SSH", "session.target": "10.0.0.1", "session.proxy": "bastion", "ssh.userName": "deploy"]
        ])
        let plan = try ConnectionBuilder.build(sessions[1], all: sessions, configPath: "/tmp/config")
        try expectTrue(plan.config!.contains("ProxyJump wn-62617374696f6e"))
        try expectTrue(plan.config!.contains("Port 2200"))
        try expectTrue(plan.config!.contains("User \"gateway\"")); try expectTrue(plan.config!.contains("User \"deploy\""))
    }
    func testCyclicJumpChainFailsBeforeLaunch() throws {
        let a = Session(id: "a", host: "a.invalid", jump: "b")
        let b = Session(id: "b", host: "b.invalid", jump: "a")
        try expectThrows(try ConnectionBuilder.build(a, all: [a,b], configPath: "/tmp/c"))
    }
    func testUnconvertedProxyNeverFallsBackToDirectConnection() throws {
        let sessions = try imported([["session.uuid": "a", "session.protocol": "SSH", "session.target": "internal.invalid", "session.proxy": "SOCKS5"]])
        try expectTrue(sessions[0].jump.hasPrefix("unsupported:"))
        try expectThrows(try ConnectionBuilder.build(sessions[0], all: sessions, configPath: "/tmp/c"))
        let commandProxy = try imported([["session.protocol": "SSH", "session.target": "internal.invalid", "ssh.proxyCommand": "nc test 22"]])
        try expectThrows(try ConnectionBuilder.build(commandProxy[0], all: commandProxy, configPath: "/tmp/c"))
    }
    func testMalformedFieldsCannotInjectSSHConfig() throws {
        for host in ["-oProxyCommand=evil", "ok\nProxyCommand evil", "$(touch /tmp/evil)", "user@host", "host name"] {
            try expectThrows(try ConnectionBuilder.build(Session(host: host), all: [], configPath: "/tmp/c"))
        }
        for jump in ["a,,b", "host:0", "host:65536", "a\nProxyCommand evil", "-oProxyCommand=evil", "user@@host", "[::1]:no"] {
            try expectThrows(try ConnectionBuilder.build(Session(host: "target.invalid", jump: jump), all: [], configPath: "/tmp/c"))
        }
        try expectThrows(try ConnectionBuilder.build(Session(host: "target.invalid", port: 0), all: [], configPath: "/tmp/c"))
    }
    func testGeneratedConfigurationAcceptedBySystemSSHWithoutNetwork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ssh.conf")
        let jump = Session(id: "jump", host: "bastion.invalid", port: 2222, username: "gateway")
        let target = Session(id: "target", host: "internal.invalid", port: 2200, username: "deploy", jump: jump.id)
        let plan = try ConnectionBuilder.build(target, all: [target, jump], configPath: path.path)
        try plan.config!.write(to: path, atomically: true, encoding: .utf8)
        let process = Process(); let output = Pipe(); let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", path.path, plan.arguments.last!]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try expectEqual(process.terminationStatus, 0, String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        let config = String(decoding: data, as: UTF8.self)
        try expectTrue(config.contains("hostname internal.invalid\n"))
        try expectTrue(config.contains("user deploy\n")); try expectTrue(config.contains("port 2200\n"))
        try expectTrue(config.contains("proxyjump wn-6a756d70\n")); try expectTrue(config.contains("serveraliveinterval 20\n"))
        try expectTrue(config.contains("stricthostkeychecking ask\n"))
    }
    func testSFTPUsesSameConnectionRoute() throws {
        let s = Session(host: "example.invalid", jump: "alice@bastion.invalid:2222,bob@[::1]:22")
        let ssh = try ConnectionBuilder.build(s, all: [s], configPath: "/tmp/c")
        let sftp = try ConnectionBuilder.build(s, all: [s], configPath: "/tmp/c", sftp: true)
        try expectEqual(sftp.executable, "/usr/bin/sftp"); try expectEqual(ssh.config, sftp.config)
        try expectFalse(sftp.arguments.contains("-tt")); try expectTrue(ssh.arguments.contains("-tt"))
    }
    func testUnreadableIdentityAndUnsupportedProtocolAreExplicitErrors() throws {
        try expectThrows(try ConnectionBuilder.build(Session(host: "a.invalid", identityFile: "/nonexistent/key"), all: [], configPath: "/tmp/c"))
        try expectThrows(try ConnectionBuilder.build(Session(kind: "Telnet", host: "a.invalid"), all: [], configPath: "/tmp/c"))
    }
    func testLocalInstalledProfileIsReadOnlyAndAllRowsRepresented() throws {
        guard let source = WindImporter.discover().first else { throw CheckSkip("WindTerm 未安装") }
        let before = try Data(contentsOf: source)
        let imported = try WindImporter.load(source)
        let rows = try JSONSerialization.jsonObject(with: before) as! [[String: Any]]
        try expectEqual(imported.sessions.count, rows.count)
        try expectEqual(Set(imported.sessions.map(\.id)).count, rows.count)
        try expectEqual(try Data(contentsOf: source), before)
        // Do not connect to private infrastructure or print imported connection details.
    }
    func testOpenSSHDefaultsSurviveGeneratedAliases() throws {
        let session = Session(id: "alias", host: "ssh-alias", port: 2222)
        let defaults = OpenSSHDefaults(values: [
            "hostname": ["real.example.invalid"], "user": ["config-user"],
            "identityfile": ["~/.ssh/config_key"], "identitiesonly": ["yes"],
            "proxyjump": ["configured-jump"], "forwardagent": ["no"]
        ])
        let plan = try ConnectionBuilder.build(session, all: [session], configPath: "/tmp/c", resolver: { _ in defaults })
        try expectTrue(plan.config!.contains("HostName real.example.invalid"))
        try expectTrue(plan.config!.contains("User \"config-user\""))
        try expectTrue(plan.config!.contains("IdentityFile \"~/.ssh/config_key\""))
        try expectTrue(plan.config!.contains("ProxyJump configured-jump"))
        var override = session; override.username = "explicit-user"; override.jump = "new-jump"
        let explicit = try ConnectionBuilder.build(override, all: [override], configPath: "/tmp/c", resolver: { _ in defaults })
        try expectTrue(explicit.config!.contains("User \"explicit-user\""))
        try expectTrue(explicit.config!.contains("ProxyJump new-jump"))
        try expectFalse(explicit.config!.contains("ProxyJump configured-jump"))
        let resolved = try OpenSSHDefaults.resolve(Session(host: "windnative-offline.invalid"))
        try expectEqual(resolved.first("hostname"), "windnative-offline.invalid")
    }

    func testNestedFoldersAndSubtreeRename() throws {
        let a = Session(id: "a", name: "A", group: "dev/api", host: "a.invalid")
        let b = Session(id: "b", name: "B", group: "dev/db", host: "b.invalid")
        let c = Session(id: "c", name: "C", group: "device", host: "c.invalid")
        let tree = SessionFolder.tree(sessions: [a,b,c], emptyFolders: ["empty/nested"])
        try expectEqual(tree.map(\.path), ["dev", "device", "empty"])
        try expectEqual(tree[0].count, 2)
        try expectEqual(tree[0].children.map(\.path), ["dev/api", "dev/db"])
        try expectEqual(tree[2].children.first?.path, "empty/nested")
        try expectEqual(SessionFolder.moved(a, from: "dev", to: "production").group, "production/api")
        try expectEqual(SessionFolder.moved(c, from: "dev", to: "production").group, "device")
        try expectEqual(SessionFolder.allPaths(sessions: [a], emptyFolders: []), ["dev", "dev/api"])
    }

}
