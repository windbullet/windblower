import SwiftUI

@main struct PureToneApp: App {
    @State private var library: LibraryStore
    @State private var audio: AudioController
    @State private var uploads: UploadServer
    @State private var lyrics = LyricsController()
    private let remote: RemoteSources
    init() {
        let library = LibraryStore()
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
