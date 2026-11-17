import SwiftUI

@main struct PureToneApp: App {
    @State private var library: LibraryStore
    @State private var audio: AudioController
    @State private var uploads: UploadServer
    @State private var lyrics = LyricsController()
    private let remote: RemoteSources
    init() {
        let library: LibraryStore
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixtures") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("UI-Test-\(UUID().uuidString).sqlite")
            let db = try! Database(url: url)
            library = LibraryStore(database: db)
            for number in 1...3 {
                let track = Track(id: "ui-\(number)", relativePath: "UIFixtures/\(number).flac", title: "测试歌曲 \(number)", artist: "测试歌手", album: "测试专辑", duration: 180, sampleRate: 48_000, bitDepth: 24, channels: 2)
                try! db.put(track, kind: "track", id: track.id)
            }
            library.save(Playlist(name: "测试歌单")); library.reload()
        } else { library = LibraryStore() }
        #else
        library = LibraryStore()
        #endif
        _library = State(initialValue: library)
        _audio = State(initialValue: AudioController(library: library))
        _uploads = State(initialValue: UploadServer(importer: library.importer))
        remote = RemoteSources(db: library.db)
    }
    var body: some Scene {
        WindowGroup {
            RootView(remote: remote)
                .environment(library).environment(audio).environment(uploads).environment(lyrics)
                .tint(Color.accentGreen)
                .onReceive(NotificationCenter.default.publisher(for: .pureToneLibraryChanged)) { _ in library.reload() }
                .onOpenURL { url in Task { await library.importFiles([url]) } }
        }
    }
}

extension Color {
    static let accentGreen = Color(red: 0.17, green: 0.55, blue: 0.42)
}
