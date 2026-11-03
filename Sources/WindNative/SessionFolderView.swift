import SwiftUI
import UniformTypeIdentifiers
import WindCore

struct SessionFolderView: View {
    let folder: SessionFolder
    @ObservedObject var model: AppModel
    @State private var dropTarget = false
    private var expanded: Binding<Bool> {
        Binding(get: { !model.query.isEmpty || model.expandedFolders.contains(folder.path) }, set: { model.setFolderExpanded(folder.path, expanded: $0) })
    }
    var body: some View {
        DisclosureGroup(isExpanded: expanded) {
            ForEach(folder.children) { child in SessionFolderView(folder: child, model: model) }
            ForEach(folder.sessions) { session in
                SessionTreeRow(session: session, model: model).tag(session.id)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder.fill").foregroundStyle(.cyan)
                Text(folder.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(folder.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(.vertical, 6).contentShape(Rectangle())
                .background(dropTarget ? Color.cyan.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contextMenu {
                    Button("新建子文件夹…") { model.folderEdit = FolderEdit(parent: folder.path) }
                    Button("重命名文件夹…") { model.folderEdit = FolderEdit(original: folder.path, parent: (folder.path as NSString).deletingLastPathComponent) }
                    Button("在此新建 SSH…") { model.editing = Session(group: folder.path) }
                    if folder.count == 0 { Button("删除空文件夹", role: .destructive) { model.removeEmptyFolder(folder.path) } }
                }
                .onDrop(of: [.utf8PlainText], isTargeted: $dropTarget) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: String.self) { id, _ in
                        guard let id else { return }
                        Task { @MainActor in
                            let ids = id.hasPrefix("myterm-sessions:") ? ((try? JSONDecoder().decode([String].self, from: Data(id.dropFirst("myterm-sessions:".count).utf8))) ?? []) : [id]
                            model.moveSessions(Set(ids), to: folder.path)
                        }
                    }
                    return true
                }
        }
    }
}

struct SessionTreeRow: View {
    let session: Session
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.kind == "Shell" ? "terminal" : "network")
                .foregroundStyle(session.supported ? Color.cyan : Color.orange).frame(width: 18)
            Text(session.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
            if !session.jump.isEmpty { Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(.vertical, 5).contentShape(Rectangle())
            .background(model.selectedSessions.contains(session.id) ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .onTapGesture(count: 2) { model.selectedSession = session.id; model.connect(session) }
            .onTapGesture { model.selectSession(session.id, modifiers: NSEvent.modifierFlags) }
            .onDrag {
                let ids = model.selectedSessions.contains(session.id) ? model.selectedSessions.sorted() : [session.id]
                let data = (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8)
                return NSItemProvider(object: ("myterm-sessions:" + String(decoding: data, as: UTF8.self)) as NSString)
            }
            .help(session.endpoint + " · 双击连接")
            .contextMenu {
                Button("连接 SSH") { model.connect(session) }.disabled(!session.supported)
                Button("打开文件管理器") { model.openFiles(session) }.disabled(session.kind != "SSH")
                Button("编辑连接…") { model.editing = session }
                Button("复制连接…") { model.duplicateSession(session) }
                Menu("移动到文件夹") {
                    ForEach(model.folderPaths, id: \.self) { path in Button(path) { model.move(session, to: path) } }
                }
                Divider()
                Button(session.isImported ? "从列表隐藏" : "删除连接", role: .destructive) { model.hide(session) }
            }
    }
}

struct FolderEditor: View {
    @ObservedObject var model: AppModel
    let edit: FolderEdit
    @State private var name: String
    init(model: AppModel, edit: FolderEdit) {
        self.model = model; self.edit = edit
        _name = State(initialValue: edit.original.map { ($0 as NSString).lastPathComponent } ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(edit.original == nil ? "新建文件夹" : "重命名文件夹", systemImage: "folder").font(.title3.bold())
            Text(edit.parent.isEmpty ? "位置：会话根目录" : "位置：\(edit.parent)").font(.caption).foregroundStyle(.secondary)
            TextField("文件夹名称", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Button("取消") { model.folderEdit = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { model.updateFolder(edit, name: name) }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).frame(width: 360)
    }
}
