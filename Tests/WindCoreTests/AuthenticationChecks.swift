import Foundation
import CommonCrypto
import WindCore

func checkWindCryptography() throws {
    let empty = WindCrypto.sha3(Data()).map { String(format: "%02x", $0) }.joined()
    try expectEqual(empty, "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26")
    let material = WindCrypto.derive(password: "test-password", fingerprint: "test-fingerprint", rounds: 1000)
    try expectEqual(material.map { String(format: "%02x", $0) }.joined(), "0ce69ce48548edd785c925dabefbba6a7ecd47dba01bbf0a6d062efabac2878fcbbf38f99976e8a55bd1f08731ec337d")
    let cipher = "WcVycCt34+GZ4Dw2XK5PylLmuzjRO7So8IG972uzA8IHDOrb7hWc6YGRSZzJvfGjZ+SCjdCgvQ4GKgopuWz1hU0uOxIE0d0wSGAZNVH/fFlIRQGyJixzCLBOcVfenZUDucuVmX4MdSYTHUthLZNQ5w=="
    let plain = try WindCrypto.decrypt(cipher, material: material)
    let record = try JSONSerialization.jsonObject(with: plain) as! [String: Any]
    try expectEqual(record["session.user"] as? String, "fixture-user")
    try expectEqual(record["Password"] as? String, "fixture-password")
    try expectThrows(try JSONSerialization.jsonObject(with: WindCrypto.decrypt(cipher, material: Data(repeating: 0, count: 48))))
}

func fixtureEncryption(_ object: [String: Any], fingerprint: String) throws -> String {
    let input = try JSONSerialization.data(withJSONObject: object)
    let material = WindCrypto.derive(password: "", fingerprint: fingerprint)
    let key = material.prefix(32), iv = material.suffix(16)
    var output = Data(count: input.count + 16), count = 0
    let capacity = output.count
    let status = output.withUnsafeMutableBytes { out in input.withUnsafeBytes { source in key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key.baseAddress, 32, iv.baseAddress, source.baseAddress, input.count, out.baseAddress, capacity, &count)
    } } } }
    try expectEqual(status, CCCryptorStatus(kCCSuccess)); output.count = count
    return output.base64EncodedString()
}

func checkSavedAuthenticationBroker() throws {
    let password = "synthetic-password-73"
    let prompt = "fixture@server.invalid's password:"
    let bindings = [AuthBinding(host: "server.invalid", username: "fixture", identityFile: "/tmp/fixture-key", password: password, passphrase: "synthetic-passphrase")]
    try expectEqual(AuthBinding.secret(for: prompt, bindings: bindings), password)
    try expectEqual(AuthBinding.secret(for: "other@server.invalid's password:", bindings: bindings), nil)
    try expectEqual(AuthBinding.secret(for: "Password:", bindings: bindings), nil)
    let conflicting = bindings + [AuthBinding(host: "server.invalid", username: "fixture", identityFile: "", password: "different")]
    try expectEqual(AuthBinding.secret(for: prompt, bindings: conflicting), nil)
    let broker = try AuthenticationBroker(bindings: bindings); defer { broker.stop() }
    try expectEqual(AuthenticationBroker.savedResponse(prompt: prompt, environment: broker.environment), password)
    try expectEqual(AuthenticationBroker.savedResponse(prompt: prompt, environment: broker.environment), nil)
    var wrongToken = broker.environment; wrongToken["WINDNATIVE_AUTH_TOKEN"] = "incorrect"
    try expectEqual(AuthenticationBroker.savedResponse(prompt: "Enter passphrase for key '/tmp/fixture-key':", environment: wrongToken), nil)
    try expectFalse(broker.environment.values.contains(password))
    if let helper = ProcessInfo.processInfo.environment["WINDNATIVE_ASKPASS_HELPER"] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["Enter passphrase for key '/tmp/fixture-key':"]
        var environment = ProcessInfo.processInfo.environment
        environment.merge(broker.environment) { _, new in new }
        process.environment = environment; process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try expectEqual(process.terminationStatus, 0)
        try expectEqual(String(decoding: data, as: UTF8.self), "synthetic-passphrase\n")
    }
}

func checkInstalledWindAuthentication() throws {
    guard let source = WindImporter.discover().first else { throw CheckSkip("WindTerm 未安装") }
    let root = source.deletingLastPathComponent().deletingLastPathComponent()
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("user.config"))) as! [String: Any]
    if config["application.masterPassword"] as? Bool == true { throw CheckSkip("主密码保护的配置未解锁") }
    let before = try Data(contentsOf: source)
    let imported = try WindImporter.load(source).sessions
    let resolver = WindAuthResolver()
    var count = 0
    for session in imported where session.windAuthentication != nil {
        let credential = try resolver.load(session.windAuthentication!)
        try expectTrue(!credential.username.isEmpty)
        let resolved = try resolver.prepare(session, all: imported)
        try expectTrue(!resolved.session.username.isEmpty)
        // Never print imported usernames, passwords, key contents or derived material.
        if let identity = credential.identityFile {
            try expectTrue(FileManager.default.isReadableFile(atPath: identity))
            try expectFalse(identity.hasSuffix(".pub"))
        }
        count += 1
    }
    try expectTrue(count > 0)
    try expectEqual(try Data(contentsOf: source), before)
}
