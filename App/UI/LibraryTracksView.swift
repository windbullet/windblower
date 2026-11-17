import SwiftUI

enum LibraryScope {
    case all, favorites, group(KeyPath<Track, String>, String), playlist(UUID)
    var playlistID: UUID? { if case .playlist(let id) = self { return id }; return nil }
    @MainActor func tracks(in library: LibraryStore) -> [Track] {
        switch self {
        case .all: return library.tracks
        case .favorites: return library.tracks.filter(\.favorite)
        case .group(let key, let name):
            return library.tracks.filter { $0[keyPath: key] == name }.sorted {
                ($0.discNumber, $0.trackNumber, $0.relativePath) < ($1.discNumber, $1.trackNumber, $1.relativePath)
            }
        case .playlist(let id):
            let tracks = Dictionary(uniqueKeysWithValues: library.tracks.map { ($0.id, $0) })
            return (library.playlists.first { $0.id == id }?.trackIDs ?? []).compactMap { tracks[$0] }
        }
    }
}

struct LibraryTracksView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AudioController.self) private var audio
    let scope: LibraryScope
    var newestFirst = false
    @State private var query = ""
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var addToPlaylist: [String]?
    @State private var showLibraryPicker = false
    @State private var confirmDelete = false
    private var allTracks: [Track] {
        let values = scope.tracks(in: library)
        return newestFirst ? values.sorted { $0.added > $1.added } : values
    }
    private var filtered: [Track] { allTracks.filter { query.isEmpty || "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query) } }
    private var selectedIDs: [String] { allTracks.filter { selected.contains($0.id) }.map(\.id) }
    var body: some View {
        List {
            Section {
                HStack {
                    Text(selecting ? "已选 \(selectedIDs.count) 首" : "\(allTracks.count) 首歌曲").foregroundStyle(.secondary)
                    Spacer()
                    if selecting {
                        Button(selected.isSuperset(of: Set(filtered.map(\.id))) && !filtered.isEmpty ? "取消全选" : "全选") {
                            let visible = Set(filtered.map(\.id))
                            if selected.isSuperset(of: visible) { selected.subtract(visible) } else { selected.formUnion(visible) }
                        }
                    } else if let first = filtered.first {
                        Button("全部播放", systemImage: "play.fill") { audio.play(filtered, startingAt: first) }.buttonStyle(.bordered)
                    }
                }
            }
            ForEach(filtered) { track in
                Button {
                    if selecting { if !selected.insert(track.id).inserted { selected.remove(track.id) } }
                    else { audio.play(filtered, startingAt: track) }
                } label: {
                    HStack {
                        if selecting { Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(Color.accentGreen) }
                        TrackRow(track: track, active: audio.current?.id == track.id)
                    }.contentShape(Rectangle())
                }.tint(.primary)
                    .accessibilityAddTraits(selected.contains(track.id) ? .isSelected : [])
                    .contextMenu {
                        Button("选择歌曲", systemImage: "checkmark.circle") { selecting = true; selected.insert(track.id) }
                        Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { audio.playNext(track) }
                        Button(track.favorite ? "取消收藏" : "收藏", systemImage: "heart") { library.favorite(track) }
                        Button("添加到歌单", systemImage: "text.badge.plus") { addToPlaylist = [track.id] }
                        if let id = scope.playlistID { Button("从歌单移除", role: .destructive) { library.removeTracks([track.id], from: id) } }
                    }
            }
        }
        .listStyle(.inset)
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? (scope.playlistID == nil ? "曲库中还没有歌曲" : "歌单中还没有歌曲") : "没有搜索结果", systemImage: "music.note.list")
                } description: { Text(scope.playlistID == nil ? "导入音乐或调整搜索条件。" : "点击加号，从现有曲库选择歌曲。")
                } actions: { if scope.playlistID != nil { Button("从曲库添加歌曲") { showLibraryPicker = true } } }
            }
        }
        .searchable(text: $query, prompt: "歌曲、歌手或专辑")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "完成" : "多选", systemImage: selecting ? "checkmark" : "checklist") {
                    selecting.toggle(); if !selecting { selected.removeAll() }
                }.disabled(allTracks.isEmpty)
            }
            if scope.playlistID != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("从曲库添加歌曲", systemImage: "plus") { showLibraryPicker = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack(spacing: 18) {
                    Button("添加到歌单", systemImage: "text.badge.plus") { addToPlaylist = selectedIDs }
                    Menu {
                        Button("收藏所选歌曲") { library.setFavorite(Set(selectedIDs), value: true) }
                        Button("取消收藏所选歌曲") { library.setFavorite(Set(selectedIDs), value: false) }
                    } label: { Label("收藏", systemImage: "heart") }
                    Spacer()
                    if let id = scope.playlistID {
                        Button("移出歌单", systemImage: "minus.circle") { library.removeTracks(Set(selectedIDs), from: id); selected.removeAll() }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
                }.font(.subheadline).padding().background(.bar).disabled(selectedIDs.isEmpty || library.importing)
            }
        }
        .confirmationDialog("删除 \(selectedIDs.count) 首本机歌曲？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除歌曲和本机音频文件", role: .destructive) {
                let ids = Set(selectedIDs)
                audio.removeFromQueue(ids)
                if library.deleteTracks(ids) { selected.removeAll(); selecting = false }
            }
        } message: { Text("同时从所有歌单中移除。若只想整理当前歌单，请使用“移出歌单”。") }
        .sheet(isPresented: Binding(get: { addToPlaylist != nil }, set: { if !$0 { addToPlaylist = nil } })) {
            PlaylistDestinationPicker(trackIDs: addToPlaylist ?? [])
        }
        .sheet(isPresented: $showLibraryPicker) {
            if let id = scope.playlistID { PlaylistLibraryPicker(playlistID: id) }
        }
        .onChange(of: library.tracks.map(\.id)) { _, ids in selected.formIntersection(Set(ids)) }
    }
}

struct PlaylistLibraryPicker: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID
    @State private var query = ""
    @State private var selected: Set<String> = []
    private var existing: Set<String> { Set(library.playlists.first { $0.id == playlistID }?.trackIDs ?? []) }
    private var filtered: [Track] { library.tracks.filter { query.isEmpty || "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack {
            List {
                Button("选择全部可添加歌曲") { selected.formUnion(filtered.map(\.id).filter { !existing.contains($0) }) }
                ForEach(filtered) { track in
                    Button { if !selected.insert(track.id).inserted { selected.remove(track.id) } } label: {
                        HStack {
                            Image(systemName: existing.contains(track.id) || selected.contains(track.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.accentGreen)
                            TrackRow(track: track)
                            if existing.contains(track.id) { Text("已添加").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.tint(.primary).disabled(existing.contains(track.id))
                }
            }.searchable(text: $query, prompt: "搜索现有曲库")
                .overlay { if library.tracks.isEmpty { ContentUnavailableView("曲库为空", systemImage: "music.note", description: Text("先导入音乐，再从这里添加到歌单。")) } }
                .navigationTitle("从曲库添加")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("添加 \(selected.count) 首") {
                        library.addTracks(library.tracks.filter { selected.contains($0.id) }.map(\.id), to: playlistID); dismiss()
                    }.disabled(selected.isEmpty) }
                }
        }
    }
}

struct PlaylistDestinationPicker: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let trackIDs: [String]
    @State private var name = ""
    @State private var creating = false
    var body: some View {
        NavigationStack {
            List {
                Button("新建歌单", systemImage: "plus") { creating = true }
                ForEach(library.playlists) { playlist in
                    Button { library.addTracks(trackIDs, to: playlist.id); dismiss() } label: {
                        Label { VStack(alignment: .leading) { Text(playlist.name); Text("\(playlist.trackIDs.count) 首歌曲").font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "music.note.list") }
                    }.tint(.primary)
                }
            }.navigationTitle("添加 \(trackIDs.count) 首到歌单")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .alert("新建歌单", isPresented: $creating) {
                    TextField("歌单名称", text: $name)
                    Button("创建并添加") {
                        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { return }
                        let playlist = Playlist(name: title); library.save(playlist); library.addTracks(trackIDs, to: playlist.id); dismiss()
                    }
                    Button("取消", role: .cancel) {}
                }
        }
    }
}
