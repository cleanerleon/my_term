import Foundation

public enum JumpMode: String, Codable, CaseIterable {
    case system, direct, session, manual
    public var title: String {
        switch self {
        case .system: return "跟随系统 SSH 配置"
        case .direct: return "直接连接"
        case .session: return "通过已保存的跳板机"
        case .manual: return "手动输入跳板链"
        }
    }
}

extension Session {
    public func effectiveJumpMode(all: [Session]) -> JumpMode {
        if let jumpMode { return jumpMode }
        if jump.isEmpty { return .system }
        return all.contains { $0.id == jump } ? .session : .manual
    }
}

public enum JumpSettings {
    /// Saved hops in client-to-target order. Manual/system routes are delegated to OpenSSH.
    public static func chain(_ target: Session, all: [Session]) throws -> [Session] {
        var active = Set<String>()
        func visit(_ session: Session) throws -> [Session] {
            guard session.kind == "SSH" else { throw WindError.invalid("跳板会话必须使用 SSH 协议。") }
            guard active.insert(session.id).inserted else { throw WindError.invalid("跳板机形成循环，请检查连接路径。") }
            defer { active.remove(session.id) }
            switch session.effectiveJumpMode(all: all) {
            case .session:
                guard let parent = all.first(where: { $0.id == session.jump }) else { throw WindError.invalid("请选择有效的跳板机会话。") }
                return try visit(parent) + [session]
            case .manual:
                guard !session.jump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WindError.invalid("请填写手动跳板链。") }
                return [session]
            case .system, .direct: return [session]
            }
        }
        return try visit(target)
    }
}
