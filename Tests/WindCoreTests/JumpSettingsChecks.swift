import Foundation
import WindCore

func checkJumpModes() throws {
    var first = Session(id: "first", host: "first.invalid", port: 2201, username: "first-user")
    first.jumpMode = .direct
    let second = Session(id: "second", host: "second.invalid", port: 2202, username: "second-user", jump: first.id)
    var target = Session(id: "target", host: "target.invalid", jump: second.id)
    target.jumpMode = .session
    let all = [first, second, target]
    try expectEqual(try JumpSettings.chain(target, all: all).map(\.id), [first.id, second.id, target.id])
    let inherited = OpenSSHDefaults(values: ["proxyjump": ["system-bastion:2222"], "proxycommand": ["false"]])
    var direct = target; direct.jumpMode = .direct
    let config = try ConnectionBuilder.build(direct, all: all, configPath: "/unused", resolver: { _ in inherited }).config!
    try expectTrue(config.contains("ProxyJump none")); try expectTrue(config.contains("ProxyCommand none"))
    try expectFalse(config.contains("system-bastion")); try expectFalse(config.contains("first.invalid"))
    var system = target; system.jumpMode = .system
    let systemConfig = try ConnectionBuilder.build(system, all: all, configPath: "/unused", resolver: { _ in inherited }).config!
    try expectTrue(systemConfig.contains("ProxyJump system-bastion:2222"))
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("direct-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try config.write(to: temporary, atomically: true, encoding: .utf8)
    let task = Process(); let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    task.arguments = ["-G", "-F", temporary.path, "wn-" + direct.id.utf8.map { String(format: "%02x", $0) }.joined()]
    task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
    try task.run(); let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); task.waitUntilExit()
    try expectEqual(task.terminationStatus, 0)
    try expectFalse(output.contains("system-bastion"))
    var missing = target; missing.jump = "deleted"; missing.jumpMode = .session
    try expectThrows(try JumpSettings.chain(missing, all: all))
    var cyclic = first; cyclic.jumpMode = .session; cyclic.jump = target.id
    try expectThrows(try JumpSettings.chain(target, all: [cyclic, second, target]))
    var manual = target; manual.jumpMode = .manual; manual.jump = ""
    try expectThrows(try ConnectionBuilder.build(manual, all: all, configPath: "/unused"))
    // Old sessions keep their existing route until explicitly edited.
    let legacy = Session(id: "legacy", host: "target.invalid", jump: first.id)
    let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(legacy))
    try expectEqual(decoded.effectiveJumpMode(all: all), .session)
}

func checkPerHopManagedAuthentication() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jump-auth-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CredentialStore(directory: directory, keyProvider: EphemeralVaultKey())
    let hopProfile = AuthenticationProfile(name: "Bastion", username: "hop-user", method: .password)
    let targetProfile = AuthenticationProfile(name: "Target", username: "target-user", method: .password)
    try store.save(hopProfile, secrets: CredentialSecrets(password: "synthetic-hop-secret"))
    try store.save(targetProfile, secrets: CredentialSecrets(password: "synthetic-target-secret"))
    var hop = Session(id: "hop", host: "hop.invalid", port: 2222); hop.credentialProfileID = hopProfile.id
    var target = Session(id: "target", host: "target.invalid", jump: hop.id); target.credentialProfileID = targetProfile.id; target.jumpMode = .session
    let resolved = try WindAuthResolver().prepare(target, all: [target, hop], store: store)
    try expectEqual(resolved.session.username, "target-user")
    try expectEqual(AuthBinding.secret(for: "hop-user@hop.invalid's password:", bindings: resolved.bindings), "synthetic-hop-secret")
    try expectEqual(AuthBinding.secret(for: "target-user@target.invalid's password:", bindings: resolved.bindings), "synthetic-target-secret")
    target.jumpMode = .direct
    let direct = try WindAuthResolver().prepare(target, all: [target, hop], store: store)
    try expectEqual(direct.bindings.count, 1)
    try expectEqual(direct.bindings.first?.host, target.host)
}
