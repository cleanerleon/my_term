import Foundation
import WindCore

func checkHostKeyChange() throws {
    let fingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    let warning = """
    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
    The fingerprint for the ED25519 key sent by the remote host is
    \(fingerprint).
    Offending ED25519 key in /tmp/known hosts:43
    Host key for fixture.example.invalid has changed and you have requested strict checking.
    Host key verification failed.
    """
    let change = try unwrap(HostKeyChange.parse(warning.replacingOccurrences(of: "\n", with: "\r\n")))
    try expectEqual(change.fingerprint, fingerprint)
    try expectEqual(change.host, "fixture.example.invalid")
    try expectEqual(change.file, "/tmp/known hosts")
    try expectEqual(change.line, 43)
    try expectEqual(HostKeyChange.parse("Permission denied (publickey)."), nil)
    try expectEqual(HostKeyChange.parse(warning.replacingOccurrences(of: fingerprint, with: "SHA256:invalid")), nil)
    let broker = try AuthenticationBroker(bindings: [], approvedHostFingerprint: fingerprint)
    defer { broker.stop() }
    let prompt = "The authenticity of host 'fixture.example.invalid' can't be established.\nED25519 key fingerprint is \(fingerprint).\nAre you sure you want to continue connecting (yes/no/[fingerprint])?"
    try expectEqual(AuthenticationBroker.savedResponse(prompt: prompt.replacingOccurrences(of: fingerprint, with: "SHA256:different"), environment: broker.environment), nil)
    try expectEqual(AuthenticationBroker.savedResponse(prompt: prompt, environment: broker.environment), "yes")
    try expectEqual(AuthenticationBroker.savedResponse(prompt: prompt, environment: broker.environment), nil)
    let ordinary = try AuthenticationBroker(bindings: [])
    defer { ordinary.stop() }
    try expectEqual(AuthenticationBroker.savedResponse(prompt: prompt, environment: ordinary.environment), nil)
}
