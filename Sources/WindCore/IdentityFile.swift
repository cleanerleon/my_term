import Foundation

public enum IdentityFile {
    /// WindTerm may store a .pub reference. Verify the public portion embedded in the
    /// OpenSSH private file before selecting its same-name private companion.
    public static func resolve(_ value: String) throws -> String {
        let path = (value as NSString).expandingTildeInPath
        guard path.hasSuffix(".pub") else { return path }
        let privatePath = String(path.dropLast(4))
        guard FileManager.default.isReadableFile(atPath: privatePath) else { throw WindError.invalid("WindTerm 指定的是公钥 .pub，未找到同名私钥，请在连接设置中指定私钥。") }
        let publicText = try String(contentsOfFile: path, encoding: .utf8)
        let parts = publicText.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, let expected = Data(base64Encoded: String(parts[1])) else { throw WindError.invalid("公钥文件格式无效。") }
        let privateText = try String(contentsOfFile: privatePath, encoding: .utf8)
        let lines = privateText.split(whereSeparator: \.isNewline)
        guard lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----", lines.count >= 3,
              let raw = Data(base64Encoded: lines.dropFirst().dropLast().joined()) else { throw WindError.invalid("无法验证 .pub 对应的私钥，请直接选择私钥文件。") }
        let magic = Data("openssh-key-v1\0".utf8)
        guard raw.starts(with: magic) else { throw WindError.invalid("OpenSSH 私钥格式无效。") }
        var packet = SFTPPacket(raw); packet.offset = magic.count
        _ = try packet.data(); _ = try packet.data(); _ = try packet.data()
        guard try packet.uint32() == 1, try packet.data() == expected else { throw WindError.invalid("公钥与同名私钥不匹配，请选择正确的私钥。") }
        return privatePath
    }
}
