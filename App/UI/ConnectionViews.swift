import SwiftUI
import CoreImage.CIFilterBuiltins

struct SignalPathView: View {
    @Environment(AudioController.self) private var audio
    @Environment(LibraryStore.self) private var library
    @State private var backupURL: URL?
    @State private var restoring = false
    @State private var backupError: String?
    var body: some View {
        List {
            Section("当前路径") {
                stage("原文件", audio.current.map { "\($0.format) · \($0.sampleRate / 1000) kHz · \($0.bitDepth > 0 ? "\($0.bitDepth) bit" : "浮点解码")" } ?? "尚未播放", symbol: "doc")
                stage("解码", audio.current?.format == "MP3" ? "libmpg123 · 原采样率浮点 PCM" : "libFLAC · 整数 PCM → Float64", symbol: "waveform")
                stage("采样率", audio.path.resampling ? "libsoxr VHQ · 双精度 · \(audio.path.sourceRate) → \(audio.path.outputRate) Hz" : "App 内 SRC 已旁路", symbol: "arrow.triangle.branch")
                let applied = audio.appliedConfiguration ?? audio.configuration
                stage("均衡器", applied.enabled ? "Float64 TPT · \(applied.bands.count) 段\(audio.transitioning ? " · 切换中" : "")" : "EQ 已旁路 · 单位增益", symbol: "slider.horizontal.3")
                stage("输出接口", "Float32 PCM → RemoteIO → iPadOS", symbol: "cpu")
                stage("实际路由", audio.path.route, symbol: "headphones")
            }
            Section("实际会话信息") {
                LabeledContent("输出采样率", value: audio.path.outputRate == 0 ? "尚未激活" : "\(Int(audio.path.outputRate)) Hz")
                LabeledContent("模式", value: audio.path.sessionMode)
                LabeledContent("混音请求", value: "不与其他 App 混音")
                LabeledContent("输出延迟", value: String(format: "%.1f ms", audio.path.outputLatency * 1000))
                LabeledContent("硬件缓冲", value: String(format: "%.1f ms", audio.path.bufferDuration * 1000))
                LabeledContent("缓冲不足次数", value: "\(audio.path.underruns)")
            }
            if let report = audio.analysis {
                Section("数字峰值与增益") {
                    LabeledContent("EQ 前输入峰值", value: decibels(report.inputPeak))
                    LabeledContent("校准前样本峰值", value: decibels(report.samplePeak))
                    LabeledContent("校准前真峰值（8×）", value: decibels(report.truePeak))
                    LabeledContent("实际前置增益", value: String(format: "%.2f dB", audio.path.effectivePreamp))
                    LabeledContent("静态安全衰减", value: String(format: "%.2f dB", audio.path.safety))
                }
            }
            Section("测量边界") {
                Text("非混音会话不等于硬件独占。实际采样率匹配只能证明 App 不需要 SRC，无法据此证明系统或 DAC 内部没有其他处理。3.5 mm 模拟输出需借助外部测量设备验证。")
                Text("开启 EQ 会有预期的幅度和相位变化。静态峰值衰减用于减少数字削波及重建峰值过载，不改变原音频文件。")
            }.font(.footnote).foregroundStyle(.secondary)
            Section { ShareLink("导出播放链路诊断", item: diagnostic, preview: SharePreview("PureTone 播放链路")) }
            Section("资料与开源声明") {
                Button("准备资料备份", systemImage: "square.and.arrow.up") {
                    do {
                        let backup = try library.db.backup(); let url = FileManager.default.temporaryDirectory.appendingPathComponent("PureTone-library-backup.json")
                        try JSONEncoder().encode(backup).write(to: url, options: .atomic); backupURL = url
                    } catch { backupError = error.localizedDescription }
                }
                if let backupURL { ShareLink("保存资料备份", item: backupURL) }
                Button("恢复资料备份", systemImage: "square.and.arrow.down") { restoring = true }
                Text("资料备份包含歌单、EQ、曲库索引与歌词；原始音乐请另行复制 Music 文件夹。NAS 密码不导出。").font(.caption).foregroundStyle(.secondary)
                NavigationLink("开源许可") { LicenseView() }
                if let backupError { Text(backupError).font(.caption).foregroundStyle(.red) }
            }
        }.navigationTitle("播放链路")
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let backup = try JSONDecoder().decode(LibraryBackup.self, from: Data(contentsOf: url))
                try library.db.restore(backup); library.reload()
                if let restored = try library.db.all(EQConfiguration.self, kind: "eq").first { audio.configuration = restored }
                audio.presets = try library.db.all(EQPreset.self, kind: "preset")
            } catch { backupError = error.localizedDescription }
        }
    }
    private func decibels(_ value: Double) -> String { value > 0 ? String(format: "%.2f dBFS", 20 * log10(value)) : "−∞ dBFS" }
    private func stage(_ title: String, _ detail: String, symbol: String) -> some View { Label { VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: symbol).foregroundStyle(Color.accentGreen).frame(width: 30) }.padding(.vertical, 6) }
    private var diagnostic: String { "PureTone \(PT_CORE_VERSION)\n源：\(audio.current?.format ?? "") \(audio.path.sourceRate) Hz\n输出：\(audio.path.outputRate) Hz\n模式：\(audio.path.sessionMode)\n路由：\(audio.path.route)\nSRC：\(audio.path.resampling)\nEQ：\((audio.appliedConfiguration ?? audio.configuration).enabled)\n切换中：\(audio.transitioning)\n增益：\(audio.path.effectivePreamp) dB\n缓冲不足：\(audio.path.underruns)\n系统/DAC 内部处理未验证" }
}

struct LicenseView: View {
    private var text: String {
        let root = Bundle.main.resourceURL!.appendingPathComponent("Resources/Licenses")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { "\($0.lastPathComponent)\n\n\((try? String(contentsOf: $0, encoding: .utf8)) ?? "")" }.joined(separator: "\n\n──────────────────\n\n")
    }
    var body: some View { ScrollView { Text(text).font(.caption.monospaced()).textSelection(.enabled).padding(24) }.navigationTitle("开源许可") }
}

struct TransferView: View {
    @Environment(UploadServer.self) private var server
    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Image(systemName: "wifi").font(.system(size: 52, weight: .light)).foregroundStyle(Color.accentGreen).padding(.top, 30)
                Text("通过 Wi-Fi，完整传入").font(.title2.bold())
                Text("让电脑与 iPad 连接同一局域网，\n在电脑浏览器打开下方地址。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                if server.running {
                    if let image = qrImage(server.address) { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 180, height: 180).padding(16).background(.white, in: .rect(cornerRadius: 18)) }
                    Text(server.address).font(.title3.monospaced()).textSelection(.enabled)
                    HStack { Text("访问码").foregroundStyle(.secondary); Text(server.code).font(.title.monospacedDigit().weight(.semibold)).tracking(5) }
                    Button("关闭传歌服务器", role: .destructive) { server.stop() }.buttonStyle(.bordered)
                } else { Button("开启 Wi-Fi 传歌", systemImage: "wifi") { server.start() }.buttonStyle(.borderedProminent).controlSize(.large) }
                if let error = server.error { Text(error).foregroundStyle(.red) }
                VStack(alignment: .leading, spacing: 14) {
                    Label("支持选择和拖入整个文件夹", systemImage: "folder")
                    Label("原文件传输，SHA-256 校验后入库", systemImage: "checkmark.shield")
                    Label("每次最多两个文件并行，支持断点续传", systemImage: "arrow.triangle.2.circlepath")
                    Label("传输时保持此 App 前台；锁屏会暂停服务器", systemImage: "ipad")
                }.font(.subheadline).foregroundStyle(.secondary).padding(24).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 18))
            }.padding(24).frame(maxWidth: .infinity)
        }.navigationTitle("Wi-Fi 传歌")
    }
    private func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct NetworkView: View {
    @Environment(LibraryStore.self) private var library
    let remote: RemoteSources
    @State private var servers: [RemoteServer] = []
    @State private var add = false
    var body: some View {
        List {
            Section { Text("连接电脑或 NAS，读取原始音频。开启 EQ 时，先缓存原文件并分析安全增益。").font(.footnote).foregroundStyle(.secondary) }
            ForEach(servers) { server in NavigationLink { RemoteBrowser(remote: remote, server: server).navigationTitle(server.name) } label: { Label { VStack(alignment: .leading) { Text(server.name); Text(server.kind.title).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(Color.accentGreen) } } }
            Button("添加服务器", systemImage: "plus") { add = true }
        }
        .task { servers = (try? await remote.servers()) ?? [] }
        .sheet(isPresented: $add, onDismiss: { Task { servers = (try? await remote.servers()) ?? [] } }) { AddServerView(remote: remote) }
    }
}

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    let remote: RemoteSources
    @State private var kind: RemoteKind = .smb
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var share = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Picker("协议", selection: $kind) { ForEach(RemoteKind.allCases) { Text($0.title).tag($0) } }
                TextField("显示名称", text: $name)
                TextField(kind == .smb ? "smb://192.168.1.10" : "https://服务器/路径", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if kind == .smb { TextField("共享名称", text: $share).textInputAutocapitalization(.never) }
                TextField("用户名（可选）", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码（保存在钥匙串）", text: $password)
                if kind == .dlna { Text("填写 MediaServer 的设备描述 URL。免费签名版本采用手动连接，不使用 SSDP 组播发现。").font(.footnote).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("添加网络音乐")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { do { try await remote.save(RemoteServer(name: name.isEmpty ? kind.title : name, kind: kind, address: address, username: username, share: share), password: password); dismiss() } catch { self.error = error.localizedDescription } } }.disabled(address.isEmpty) }
            }
        }
    }
}

struct RemoteBrowser: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AudioController.self) private var audio
    let remote: RemoteSources
    let server: RemoteServer
    var path = ""
    @State private var items: [RemoteItem] = []
    @State private var loading = true
    @State private var status = ""
    @State private var error: String?
    var body: some View {
        List {
            if loading { HStack { ProgressView(); Text(status.isEmpty ? "读取目录…" : status).font(.subheadline) } }
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(items) { item in
                if item.isDirectory { NavigationLink { RemoteBrowser(remote: remote, server: server, path: item.id).navigationTitle(item.title) } label: { Label(item.title, systemImage: "folder") } }
                else {
                    Button { Task { await play(item) } } label: {
                        Label { VStack(alignment: .leading, spacing: 4) { Text(item.title); Text(item.originalStatus).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "music.note") }
                    }.disabled(loading || item.explicitlyTranscoded).contextMenu {
                        Button("缓存后播放（支持 EQ）") { Task { await cacheAndPlay(item) } }
                    }
                }
            }
        }
        .task { do { items = try await remote.browse(server, path: path) } catch { self.error = error.localizedDescription }; loading = false }
        .refreshable { do { items = try await remote.browse(server, path: path) } catch { self.error = error.localizedDescription } }
    }
    private func play(_ item: RemoteItem) async {
        if audio.configuration.enabled { await cacheAndPlay(item); return }
        loading = true; status = "连接原文件串流…"; defer { loading = false }
        do {
            let source = try await remote.stream(item, server: server)
            await audio.playStream(source, title: item.title, provenance: item.originalStatus)
        } catch { self.error = error.localizedDescription }
    }
    private func cacheAndPlay(_ item: RemoteItem) async {
        loading = true; status = "缓存原始音频…"; defer { loading = false }
        do {
            let url = try await remote.cachedOriginal(item, server: server)
            // The cache is kept separately. Library receives an original byte-for-byte copy.
            let title = item.title.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: ":", with: "_")
            let file = ["flac", "mp3"].contains((title as NSString).pathExtension.lowercased()) ? title : title + "." + url.pathExtension
            let relative = "网络音乐/\(server.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_"))/\(file)"
            if let track = try await library.importer.ingest(url, relative: relative, move: false) { library.reload(); audio.play([track], startingAt: track) }
        } catch { self.error = error.localizedDescription }
    }
}
