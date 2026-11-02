import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WindCore

struct FileBrowserView: View {
    @ObservedObject var browser: RemoteBrowser
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "lock.shield").foregroundStyle(browser.connected ? .mint : .secondary)
                Text(browser.session.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if browser.busy { ProgressView().controlSize(.small) }
                Button { browser.connected || browser.busy ? browser.disconnect() : browser.connect() } label: { Image(systemName: browser.connected || browser.busy ? "xmark.circle" : "bolt.horizontal.circle") }
                    .help(browser.connected || browser.busy ? "断开 SFTP / 取消操作" : "连接 SFTP")
            }.padding(.horizontal, 12).frame(height: 34)
            HStack(spacing: 8) {
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack).help("后退")
                Button { browser.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!browser.canGoForward).help("前进")
                TextField("远程路径", text: $browser.pathInput).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .onSubmit { browser.navigate(browser.pathInput) }.disabled(!browser.connected || browser.busy)
                Button { browser.up() } label: { Image(systemName: "arrow.up") }.help("上级目录")
                Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
                Menu {
                    Toggle("显示隐藏文件", isOn: $browser.showHidden)
                    Button("返回主目录") { browser.navigate(".") }
                    Divider()
                    ForEach(Array(browser.history.enumerated()), id: \.offset) { index, path in
                        Button(path) { browser.navigate(path, historyIndex: index) }
                    }
                    Divider()
                    Button("新建文件夹…") { browser.mkdir() }
                    Button("上传文件…") { browser.chooseUpload() }
                    Button("重新连接") { browser.disconnect(); browser.connect() }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.padding(10).disabled(!browser.connected || browser.busy)
            Divider()
            if let failure = browser.failure {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(failure).font(.system(size: 11)).textSelection(.enabled).lineLimit(6)
                    Spacer(minLength: 0)
                    Button { browser.failure = nil } label: { Image(systemName: "xmark") }
                }.padding(10).background(Color.orange.opacity(0.07))
                Divider()
            }
            if browser.connected {
                fileTable
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(browser.busy ? "正在建立安全连接…" : "SFTP 文件管理器").font(.headline)
                    Text(browser.busy ? "如需认证，请在弹出的 SSH 对话框中输入。" : "浏览远程目录，上传和下载文件。").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !browser.busy { Button("连接文件管理器") { browser.connect() }.buttonStyle(.borderedProminent) }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                Text("\(browser.visible.count) 项").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { browser.chooseUpload() } label: { Image(systemName: "square.and.arrow.up") }.help("上传文件")
                Button { if let entry = browser.selectedEntry { browser.download(entry) } } label: { Image(systemName: "square.and.arrow.down") }.help("下载所选文件").disabled(browser.selectedEntry == nil || browser.selectedEntry?.isDirectory == true)
                Button { browser.mkdir() } label: { Image(systemName: "folder.badge.plus") }.help("新建文件夹")
            }.padding(.horizontal, 12).frame(height: 34).disabled(!browser.connected || browser.busy)
            Divider()
            transfers
        }.buttonStyle(.borderless)
    }
    private var fileTable: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("筛选文件", text: $browser.filter).textFieldStyle(.plain)
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 8)
            Table(browser.visible, selection: $browser.selected) {
                TableColumn("名称") { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : entry.isSymbolicLink ? "link" : "doc")
                            .foregroundStyle(entry.isDirectory ? Color.cyan : Color.secondary)
                        Text(entry.name).lineLimit(1)
                    }.font(.system(size: 12)).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle()).onTapGesture(count: 2) { browser.open(entry) }
                        .contextMenu {
                            if entry.isDirectory || entry.isSymbolicLink { Button("打开") { browser.open(entry) } }
                            if !entry.isDirectory { Button("下载…") { browser.download(entry) } }
                            Button("重命名…") { browser.rename(entry) }
                            Divider()
                            Button("删除…", role: .destructive) { browser.remove(entry) }
                            Button("复制远程路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string) }
                        }
                }.width(min: 110, ideal: 180)
                TableColumn("修改时间") { entry in
                    Text(entry.modified.map { $0.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) } ?? "—").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }.width(min: 82, ideal: 90, max: 105)
                TableColumn("大小") { entry in
                    Text(entry.isDirectory ? "—" : entry.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—").font(.system(size: 10)).foregroundStyle(.secondary)
                }.width(min: 45, ideal: 55, max: 75)
            }.tableStyle(.inset(alternatesRowBackgrounds: false)).disabled(browser.busy)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard browser.connected, !browser.busy else { return false }
                    Task { @MainActor in
                        var urls: [URL] = []
                        for provider in providers {
                            let url: URL? = await withCheckedContinuation { continuation in
                                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                            }
                            if let url, url.isFileURL { urls.append(url) }
                        }
                        browser.upload(urls)
                    }
                    return true
                }
        }
    }
    private var transfers: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("传输", systemImage: "arrow.up.arrow.down").font(.system(size: 11, weight: .medium))
                Spacer()
                if browser.busy { Button("取消") { browser.disconnect() }.font(.caption) }
            }.padding(10)
            if browser.transfers.isEmpty {
                Text("上传和下载任务将显示在这里").font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(browser.transfers) { transfer in
                            HStack(spacing: 8) {
                                Image(systemName: transfer.upload ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(.cyan)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text(transfer.name).lineLimit(1); Spacer(); Text(transfer.status).foregroundStyle(.secondary) }
                                    ProgressView(value: transfer.fraction).tint(.cyan)
                                }.font(.system(size: 10))
                            }
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
            }
        }.frame(height: 142).background(Color.primary.opacity(0.025))
    }
}
