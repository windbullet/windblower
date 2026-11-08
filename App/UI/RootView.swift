import SwiftUI
import UniformTypeIdentifiers
import MediaPlayer
import CoreImage.CIFilterBuiltins

enum Destination: String, CaseIterable, Identifiable {
    case songs = "全部歌曲", albums = "专辑", artists = "歌手", folders = "文件夹", favorites = "收藏", playlists = "歌单", network = "网络音乐", transfer = "Wi-Fi 传歌", eq = "参数均衡器", signal = "播放链路"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .songs: "music.note.list"; case .albums: "square.stack"; case .artists: "person.2"
        case .folders: "folder"; case .favorites: "heart"; case .playlists: "text.badge.plus"
        case .network: "network"; case .transfer: "wifi"; case .eq: "slider.horizontal.3"; case .signal: "waveform.path"
        }
    }
}

struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AudioController.self) private var audio
    @Environment(UploadServer.self) private var uploads
    @Environment(\.scenePhase) private var scenePhase
    let remote: RemoteSources
    @State private var selection: Destination? = .songs
    @State private var showPlayer = false
    @State private var importing = false
    @State private var importFolder = false
    @State private var query = ""
    @State private var playlistName = ""
    @State private var newPlaylist = false
    @State private var sortNewest = false
    @State private var transferWasRunning = false

    var body: some View {
        @Bindable var library = library
        @Bindable var audio = audio
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach([Destination.songs, .albums, .artists, .folders, .favorites, .playlists]) { item in Label(item.rawValue, systemImage: item.symbol).tag(item) }
                } header: { Text("你的音乐") }
                Section {
                    ForEach([Destination.network, .transfer]) { item in Label(item.rawValue, systemImage: item.symbol).tag(item) }
                } header: { Text("连接") }
                Section {
                    ForEach([Destination.eq, .signal]) { item in Label(item.rawValue, systemImage: item.symbol).tag(item) }
                } header: { Text("声音") }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PURETONE").font(.caption.weight(.bold)).tracking(3)
                        Text("让音乐，保持本来。\n\(library.tracks.count) 首原版音频").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
            }
            .navigationTitle("PureTone")
            .toolbar { ToolbarItem(placement: .primaryAction) { importMenu } }
        } detail: {
            NavigationStack {
                Group {
                    switch selection ?? .songs {
                    case .eq: EqualizerView()
                    case .signal: SignalPathView()
                    case .transfer: TransferView()
                    case .network: NetworkView(remote: remote)
                    case .albums: groupedList(key: \.album, symbol: "square.stack")
                    case .artists: groupedList(key: \.artist, symbol: "person")
                    case .folders: groupedList(key: \.folder, symbol: "folder")
                    case .playlists: playlistsView
                    default: trackList(filtered)
                    }
                }
                .navigationTitle(selection?.rawValue ?? "全部歌曲")
                .toolbar {
                    if [.songs, .favorites].contains(selection ?? .songs) {
                        ToolbarItem(placement: .primaryAction) { Menu { Toggle("最近添加优先", isOn: $sortNewest) } label: { Image(systemName: "arrow.up.arrow.down") } }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { if audio.current != nil { miniPlayer } }
        .sheet(isPresented: $showPlayer) { PlayerView().presentationDragIndicator(.visible) }
        .fileImporter(isPresented: $importing, allowedContentTypes: importFolder ? [.folder] : [.audio, .data], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): Task { await library.importFiles(urls) }; case .failure(let error): library.error = error.localizedDescription }
        }
        .alert("提示", isPresented: Binding(get: { library.error != nil || audio.error != nil }, set: { if !$0 { library.error = nil; audio.error = nil } })) {
            Button("知道了") { library.error = nil; audio.error = nil }
        } message: { Text(library.error ?? audio.error ?? "") }
        .alert("新建歌单", isPresented: $newPlaylist) {
            TextField("歌单名称", text: $playlistName)
            Button("创建") { let name = playlistName.trimmingCharacters(in: .whitespaces); if !name.isEmpty { library.save(Playlist(name: name)) }; playlistName = "" }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { transferWasRunning = uploads.running; uploads.stop() }
            else if phase == .active && transferWasRunning { uploads.start(); transferWasRunning = false }
        }
    }
    private var filtered: [Track] {
        let tracks = library.tracks.filter { (selection != .favorites || $0.favorite) && (query.isEmpty || "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query)) }
        return sortNewest ? tracks.sorted { $0.added > $1.added } : tracks
    }
    private var importMenu: some View {
        Menu {
            Button("导入音乐文件", systemImage: "doc.badge.plus") { importFolder = false; importing = true }
            Button("导入整个文件夹", systemImage: "folder.badge.plus") { importFolder = true; importing = true }
            Button("扫描本机 Music 文件夹", systemImage: "arrow.clockwise") { Task { do { _ = try await library.importer.rescan(); library.reload() } catch { library.error = error.localizedDescription } } }
        } label: { if library.importing { ProgressView() } else { Image(systemName: "plus") } }
    }
    @ViewBuilder private func trackList(_ tracks: [Track]) -> some View {
        if tracks.isEmpty {
            ContentUnavailableView { Label("音乐，从这里开始", systemImage: "waveform") } description: { Text("导入 FLAC / MP3，或开启 Wi-Fi 传歌。\n音频以原文件保存。") } actions: { importMenu }
        } else {
            List {
                Section {
                    HStack { Text("\(tracks.count) 首歌曲").foregroundStyle(.secondary); Spacer(); Button("全部播放", systemImage: "play.fill") { audio.play(tracks, startingAt: tracks[0]) }.buttonStyle(.bordered) }
                }
                ForEach(tracks) { track in
                    Button { audio.play(tracks, startingAt: track) } label: { TrackRow(track: track, active: audio.current?.id == track.id) }
                        .tint(.primary)
                        .contextMenu {
                            Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { audio.playNext(track) }
                            Button(track.favorite ? "取消收藏" : "收藏", systemImage: track.favorite ? "heart.slash" : "heart") { library.favorite(track) }
                            Menu("添加到歌单") { ForEach(library.playlists) { playlist in Button(playlist.name) { var p = playlist; if !p.trackIDs.contains(track.id) { p.trackIDs.append(track.id); library.save(p) } } } }
                        }
                }
            }.listStyle(.inset).searchable(text: $query, prompt: "歌曲、歌手或专辑")
        }
    }
    private func groupedList(key: KeyPath<Track, String>, symbol: String) -> some View {
        let groups = Dictionary(grouping: library.tracks, by: { $0[keyPath: key] })
        return List(groups.keys.sorted(), id: \.self) { name in
            NavigationLink { trackList((groups[name] ?? []).sorted { ($0.discNumber, $0.trackNumber, $0.relativePath) < ($1.discNumber, $1.trackNumber, $1.relativePath) }).navigationTitle(name) } label: {
                Label { VStack(alignment: .leading) { Text(name.isEmpty ? "根目录" : name); Text("\(groups[name]?.count ?? 0) 首歌曲").font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: symbol).foregroundStyle(Color.accentGreen) }
            }
        }
    }
    private var playlistsView: some View {
        List {
            Button("新建歌单", systemImage: "plus") { newPlaylist = true }
            ForEach(library.playlists) { playlist in
                NavigationLink { trackList(playlist.trackIDs.compactMap { id in library.tracks.first { $0.id == id } }).navigationTitle(playlist.name) } label: {
                    Label(playlist.name, systemImage: "music.note.list")
                }
            }
        }
    }
    private var miniPlayer: some View {
        HStack(spacing: 14) {
            Button { showPlayer = true } label: {
                HStack(spacing: 12) { ArtworkView(track: audio.current).frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 9)); VStack(alignment: .leading, spacing: 3) { Text(audio.current?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1); Text(audio.preparing ? audio.status : (audio.current?.artist ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
            }.buttonStyle(.plain)
            Spacer(minLength: 10)
            if audio.preparing { ProgressView() }
            Button { audio.toggle() } label: { Image(systemName: audio.playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 40, height: 44) }.disabled(audio.preparing)
            Button { audio.next() } label: { Image(systemName: "forward.end.fill").font(.title3).frame(width: 40, height: 44) }
        }.padding(.horizontal, 22).padding(.vertical, 12).background(.bar)
    }
}

struct ArtworkView: View {
    let track: Track?
    var body: some View {
        if let art = track?.artworkPath, let image = UIImage(contentsOfFile: Paths.artwork.appendingPathComponent(art).path) { Image(uiImage: image).resizable().scaledToFill() }
        else { ZStack { LinearGradient(colors: [Color.accentGreen.opacity(0.7), Color(red: 0.09, green: 0.22, blue: 0.19)], startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "waveform").resizable().scaledToFit().padding(35).foregroundStyle(.white.opacity(0.7)) }.clipped() }
    }
}

struct TrackRow: View {
    let track: Track
    var active = false
    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(track: track).frame(width: 48, height: 48).clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) { Text(track.title).font(.body.weight(active ? .semibold : .regular)).foregroundStyle(active ? Color.accentGreen : .primary).lineLimit(1); Text("\(track.artist) · \(track.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) { Text(track.format).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Color.accentGreen); Text(timeString(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }.padding(.vertical, 5)
    }
}

func timeString(_ seconds: Double) -> String { let n = Int(max(0, seconds.isFinite ? seconds : 0)); return String(format: "%d:%02d", n / 60, n % 60) }

struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { let view = MPVolumeView(); view.showsRouteButton = false; return view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
