import Foundation

public struct SessionFolder: Identifiable {
    public let path: String
    public let name: String
    public var children: [SessionFolder]
    public var sessions: [Session]
    public var id: String { path }
    public var count: Int { sessions.count + children.reduce(0) { $0 + $1.count } }

    public static func tree(sessions: [Session], emptyFolders: [String] = []) -> [SessionFolder] {
        let paths = Set(sessions.map { normalized($0.group) } + emptyFolders.map(normalized))
        func children(_ parent: String) -> [SessionFolder] {
            let prefix = parent.isEmpty ? "" : parent + "/"
            let names = Set(paths.compactMap { path -> String? in
                guard path.hasPrefix(prefix), path != parent else { return nil }
                return String(path.dropFirst(prefix.count).split(separator: "/").first ?? "")
            }).filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return names.map { name in
                let path = prefix + name
                return SessionFolder(path: path, name: name, children: children(path), sessions: sessions.filter { normalized($0.group) == path }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
        }
        return children("")
    }
    public static func normalized(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        return parts.isEmpty ? "未分组" : parts.joined(separator: "/")
    }
    public static func allPaths(sessions: [Session], emptyFolders: [String]) -> [String] {
        var paths = Set<String>()
        for path in sessions.map(\.group) + emptyFolders {
            let parts = normalized(path).split(separator: "/")
            for index in 1...parts.count { paths.insert(parts.prefix(index).joined(separator: "/")) }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    public static func moved(_ session: Session, from folder: String, to destination: String) -> Session {
        var session = session
        let current = normalized(session.group)
        if current == folder || current.hasPrefix(folder + "/") {
            session.group = normalized(destination) + current.dropFirst(folder.count)
        }
        return session
    }
}
