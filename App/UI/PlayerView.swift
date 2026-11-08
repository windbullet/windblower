import SwiftUI

struct PlayerView: View {
    @Environment(AudioController.self) private var audio
    @Environment(LibraryStore.self) private var library
    @Environment(LyricsController.self) private var lyrics
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var seeking: Double?
    @State private var search = ""
    @State private var showSearch = false
    var body: some View {
        @Bindable var audio = audio
        NavigationStack {
            GeometryReader { geometry in
                let wide = geometry.size.width > geometry.size.height
                Group {
                    if wide { HStack(spacing: 32) { cover.frame(maxWidth: geometry.size.width * 0.4); VStack { lyricsView; controls } } }
                    else { ScrollView { VStack(spacing: 24) { if tab == 0 { cover.frame(maxWidth: 360) } else { lyricsView.frame(minHeight: 330) }; controls } } }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("正在播放").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("收起", systemImage: "chevron.down") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Menu {
                    Button("封面 / 歌词", systemImage: "quote.bubble") { tab = 1 - tab }
                    NavigationLink("播放队列") { queueView }
                    NavigationLink("参数均衡器") { EqualizerView() }
                    NavigationLink("播放链路") { SignalPathView() }
                    Menu("定时停止") { ForEach([15, 30, 45, 60], id: \.self) { minutes in Button("\(minutes) 分钟后") { audio.sleepDeadline = Date().addingTimeInterval(Double(minutes * 60)) } }; Button("关闭定时") { audio.sleepDeadline = nil } }
                } label: { Image(systemName: "ellipsis.circle") } }
            }
        }
        .task(id: audio.current?.id) { if let track = audio.current { lyrics.load(track) } }
        .alert("搜索歌词", isPresented: $showSearch) { TextField("歌手 歌名", text: $search); Button("搜索") { if let track = audio.current { lyrics.load(track, keyword: search) } }; Button("取消", role: .cancel) {} }
    }
    private var cover: some View {
        VStack(spacing: 22) {
            ArtworkView(track: audio.current).aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 22)).shadow(color: .black.opacity(0.14), radius: 24, y: 12)
            HStack { Text(audio.current?.format ?? ""); Text("\((audio.current?.sampleRate ?? 0) / 1000, specifier: "%.1f") kHz"); if let depth = audio.current?.bitDepth, depth > 0 { Text("\(depth) bit") } }.font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
    private var controls: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) { Text(audio.current?.title ?? "").font(.title2.weight(.semibold)).lineLimit(2); Text(audio.current?.artist ?? "").foregroundStyle(.secondary) }
                Spacer(); if let track = audio.current { Button { library.favorite(track) } label: { Image(systemName: library.tracks.first { $0.id == track.id }?.favorite == true ? "heart.fill" : "heart").font(.title3) } }
            }
            VStack(spacing: 5) {
                Slider(value: Binding(get: { seeking ?? audio.progress }, set: { seeking = $0 }), in: 0...max(1, audio.current?.duration ?? 1), onEditingChanged: { editing in if !editing, let position = seeking { audio.seek(position); seeking = nil } })
                HStack { Text(timeString(seeking ?? audio.progress)); Spacer(); Text(timeString(audio.current?.duration ?? 0)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 30) {
                Button { audio.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(audio.shuffle ? Color.accentGreen : .secondary) }
                Button { audio.previous() } label: { Image(systemName: "backward.end.fill").font(.title2) }
                Button { audio.toggle() } label: { ZStack { Circle().fill(Color.accentGreen).frame(width: 68, height: 68); if audio.preparing { ProgressView().tint(.white) } else { Image(systemName: audio.playing ? "pause.fill" : "play.fill").font(.title).foregroundStyle(.white) } } }.disabled(audio.preparing)
                Button { audio.next() } label: { Image(systemName: "forward.end.fill").font(.title2) }
                Button { audio.repeatMode = audio.repeatMode == .off ? .all : (audio.repeatMode == .all ? .one : .off) } label: { Image(systemName: audio.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(audio.repeatMode == .off ? .secondary : Color.accentGreen) }
            }.buttonStyle(.plain)
            SystemVolumeView().frame(height: 30).padding(.horizontal, 12)
            Text(audio.status).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
        }
    }
    private var lyricsView: some View {
        VStack {
            HStack {
                Text(lyrics.current.map { "\($0.source) · \($0.qualityName)" } ?? "歌词").font(.caption).foregroundStyle(.secondary)
                Spacer(); if lyrics.loading { ProgressView().controlSize(.small) }
                Menu {
                    Button("手动搜索") { search = "\(audio.current?.artist ?? "") \(audio.current?.title ?? "")"; showSearch = true }
                    ForEach(lyrics.candidates) { candidate in Button("\(candidate.source) · \(candidate.qualityName) · \(candidate.title)") { lyrics.select(candidate) } }
                    Button("歌词提前 0.2 秒") { lyrics.offset((lyrics.current?.offset ?? 0) + 0.2) }
                    Button("歌词延后 0.2 秒") { lyrics.offset((lyrics.current?.offset ?? 0) - 0.2) }
                } label: { Image(systemName: "ellipsis") }
            }
            if let value = lyrics.current {
                let time = audio.progress - audio.path.outputLatency - audio.path.bufferDuration + value.offset
                let active = value.lines.last { ($0.start ?? .infinity) <= time }?.id
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(value.lines) { line in
                                Text(attributed(line, time: time, active: line.id == active || value.quality == 0))
                                    .font(.system(size: 25, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                                    .onTapGesture { if let start = line.start { audio.seek(start) } }
                            }
                        }.padding(.vertical, 32)
                    }.onChange(of: active) { _, id in if let id { withAnimation(.easeInOut(duration: 0.35)) { scroll.scrollTo(id, anchor: .center) } } }
                }
            } else { ContentUnavailableView(lyrics.loading ? "正在匹配歌词" : "暂无匹配歌词", systemImage: "quote.bubble", description: Text(lyrics.message)) }
        }
    }
    private func attributed(_ line: LyricLine, time: Double, active: Bool) -> AttributedString {
        if line.words.isEmpty { var text = AttributedString(line.text); text.foregroundColor = active ? .primary : .secondary; return text }
        return line.words.reduce(AttributedString()) { result, word in
            var part = AttributedString(word.text); part.foregroundColor = time >= word.start ? Color.accentGreen : (active ? .primary : .secondary); return result + part
        }
    }
    private var queueView: some View {
        List(Array(audio.queue.enumerated()), id: \.offset) { i, track in Button { audio.play(audio.queue, startingAt: track) } label: { TrackRow(track: track, active: i == audio.index) }.tint(.primary) }.navigationTitle("播放队列")
    }
}
