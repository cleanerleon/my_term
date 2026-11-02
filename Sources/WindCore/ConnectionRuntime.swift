import Foundation

/// OpenSSH expands ProxyJump into a shell command containing its -F path.
/// Use a private path without spaces so nested SSH invocations keep it intact.
public enum ConnectionRuntime {
    public static func newDirectoryURL() -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("windnative-" + UUID().uuidString, isDirectory: true)
    }
    public static func create(_ url: URL) throws {
        guard url.path.hasPrefix("/tmp/windnative-"), !url.path.contains(where: { $0.isWhitespace }) else {
            throw WindError.invalid("SSH 运行目录无效。")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
