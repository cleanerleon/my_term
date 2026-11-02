import SwiftUI
import WindCore

struct WorkspaceDock: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(BottomPanel.allCases, id: \.self) { panel in
                    Button {
                        model.bottomPanel = panel
                    } label: {
                        Text(panel.rawValue).font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 14).frame(height: 29)
                            .background(model.bottomPanel == panel ? Color.white.opacity(0.08) : .clear)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Button { model.showBottomPanel = false; model.saveWorkspace() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("隐藏底部面板").padding(.trailing, 12)
            }.background(Color(nsColor: .controlBackgroundColor))
            Divider()
            switch model.bottomPanel {
            case .sender: sender
            case .sessions: sessions
            case .transfers: transfers
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private var sender: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack { Text("常用命令"); Spacer(); Text("\(model.commands.count)").foregroundStyle(.secondary) }.font(.system(size: 10)).padding(9)
                Divider()
                if model.commands.isEmpty {
                    Text("编辑右侧内容，点击「保存为常用」。").font(.system(size: 11)).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(model.commands) { command in
                                Button { model.senderText = command.text } label: {
                                    Label(command.name, systemImage: "text.alignleft").font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                        .padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("载入命令供编辑")
                                    .contextMenu {
                                        Button("移除常用命令") { model.commands.removeAll { $0.id == command.id }; model.saveWorkspace() }
                                    }
                            }
                        }
                    }
                }
            }.frame(minWidth: 150, idealWidth: 210, maxWidth: 320)
            VStack(spacing: 0) {
                HStack {
                    Label(model.currentTab.map { "发送到：" + $0.title } ?? "请选择终端", systemImage: "terminal")
                    Spacer()
                    Text("仅当前窗格").foregroundStyle(.secondary)
                }.font(.system(size: 10)).padding(.horizontal, 10).frame(height: 28)
                TextEditor(text: $model.senderText).font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(.horizontal, 6)
                    .accessibilityLabel("待发送命令")
                Divider()
                HStack(spacing: 10) {
                    Toggle("末尾回车", isOn: $model.senderAppendsReturn).toggleStyle(.checkbox)
                    Button("清空") { model.senderText = "" }
                    Button("保存为常用") { model.saveCommand() }.disabled(model.senderText.isEmpty)
                    Spacer()
                    Button { model.sendCommand() } label: { Label("发送", systemImage: "paperplane") }
                        .buttonStyle(.borderedProminent).disabled(model.currentTab?.running != true || model.senderText.isEmpty)
                }.font(.system(size: 11)).padding(8)
            }.frame(minWidth: 310)
        }
    }
    private var sessions: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.tabs) { tab in ActiveTerminalRow(tab: tab, model: model) }
                if model.tabs.isEmpty { Text("打开的终端会显示在这里").foregroundStyle(.secondary).font(.caption).padding(30) }
            }
        }
    }
    private var transfers: some View {
        ScrollView {
            VStack(spacing: 0) {
                if model.browsers.isEmpty { Text("SFTP 上传与下载任务会显示在这里").foregroundStyle(.secondary).font(.caption).padding(30) }
                ForEach(model.browsers.keys.sorted(), id: \.self) { id in
                    if let browser = model.browsers[id] { TransferQueueSection(browser: browser) }
                }
            }
        }
    }
}

private struct ActiveTerminalRow: View {
    @ObservedObject var tab: TerminalTab
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(tab.running ? Color.green : .secondary).frame(width: 6, height: 6)
            Button(tab.title) { model.activeTab = tab.id }.buttonStyle(.plain).frame(width: 150, alignment: .leading).lineLimit(1)
            Text(tab.session.group).foregroundStyle(.secondary).frame(width: 100, alignment: .leading).lineLimit(1)
            Text(tab.session.host).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 10)
            Text(tab.status).foregroundStyle(.secondary)
            Button { model.close(tab) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 30)
            .background(model.activeTab == tab.id ? Color.cyan.opacity(0.07) : .clear)
        Divider()
    }
}

private struct TransferQueueSection: View {
    @ObservedObject var browser: RemoteBrowser
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(browser.session.name, systemImage: "server.rack").fontWeight(.medium)
                Spacer()
                Text(browser.message).foregroundStyle(.secondary).lineLimit(1)
                if browser.busy { Button("取消") { browser.disconnect() }.buttonStyle(.borderless) }
            }
            if browser.transfers.isEmpty { Text("暂无传输任务").foregroundStyle(.tertiary) }
            ForEach(browser.transfers) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.upload ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(.cyan)
                    Text(item.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    ProgressView(value: item.fraction).frame(width: 150)
                    Text(item.status).foregroundStyle(.secondary).frame(width: 65)
                }
            }
        }.font(.system(size: 11)).padding(12)
        Divider()
    }
}
