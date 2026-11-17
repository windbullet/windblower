import Foundation
import CryptoKit
import AVFoundation
import Observation

final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw PureToneError.message("无法打开曲库数据库")
        }
        try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS records (kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind,id)); PRAGMA user_version=1;")
    }
    deinit { sqlite3_close(db) }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> PureToneError { .message(db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error") }
    func remove(kind: String, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM records WHERE kind=? AND id=?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient); sqlite3_bind_text(statement, 2, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    func put<T: Encodable>(_ value: T, kind: String, id: String) throws {
        let data = try JSONEncoder().encode(value)
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO records(kind,id,payload) VALUES(?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        sqlite3_bind_text(statement, 2, id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    func all<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM records WHERE kind=?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(statement, 0))
            if let bytes = sqlite3_column_blob(statement, 0) {
                result.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: n)))
            }
        }
        return result
    }
    func get<T: Decodable>(_ type: T.Type, kind: String, id: String) throws -> T? {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM records WHERE kind=? AND id=?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient); sqlite3_bind_text(statement, 2, id, -1, transient)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return try JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
}

enum FileIntegrity {
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func safeRelative(_ path: String) throws -> String {
        let components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !path.hasPrefix("/"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains(":") || $0.contains("\0") }), path.utf8.count < 2048 else {
            throw PureToneError.message("无效的文件相对路径")
        }
        return components.joined(separator: "/")
    }
    static func relativePath(_ file: URL, beneath root: URL) throws -> String {
        // /var and /private/var can name the same sandbox. Compare resolved components,
        // never remove a character count taken from a differently spelled base URL.
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let components = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard components.count > base.count, Array(components.prefix(base.count)) == base else {
            throw PureToneError.message("文件不在指定的音乐目录内")
        }
        return try safeRelative(components.dropFirst(base.count).joined(separator: "/"))
    }
    static func musicURL(_ relative: String) throws -> URL {
        let file = Paths.music.appendingPathComponent(try safeRelative(relative))
        _ = try relativePath(file, beneath: Paths.music)
        return file
    }
    static func inspect(_ url: URL) throws -> (bytes: UInt64, header: String) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let header = try file.read(upToCount: 16) ?? Data()
        let size = try file.seekToEnd()
        guard size > 0 else { throw PureToneError.message("音频文件为空") }
        return (size, header.map { String(format: "%02x", $0) }.joined())
    }
}

actor ImportService {
    let db: Database
    init(db: Database) { self.db = db }
    private func regularFiles(in directory: URL) -> [URL] {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let file as URL in entries where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(file) }
        return files
    }
    func importURLs(_ urls: [URL]) async throws -> [Track] {
        var result: [Track] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                for file in regularFiles(in: url) {
                    if let t = try await ingest(file, relative: FileIntegrity.relativePath(file, beneath: url.deletingLastPathComponent()), move: false) { result.append(t) }
                }
            } else if let t = try await ingest(url, relative: url.lastPathComponent, move: false) { result.append(t) }
        }
        return result
    }
    func ingest(_ source: URL, relative: String, move: Bool) async throws -> Track? {
        let relative = try FileIntegrity.safeRelative(relative)
        let ext = source.pathExtension.lowercased()
        guard ["flac", "mp3", "lrc", "txt", "yrc", "krc", "qrc", "jpg", "jpeg", "png"].contains(ext) else { return nil }
        var target = Paths.music.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            if try FileIntegrity.sha256(source) == FileIntegrity.sha256(target) {
                if move && source != target { try FileManager.default.removeItem(at: source) }
                return try await index(target, hash: try FileIntegrity.sha256(target))
            }
            let stem = target.deletingPathExtension().lastPathComponent
            target = target.deletingLastPathComponent().appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).\(ext)")
        }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        let sourceHash = try FileIntegrity.sha256(source)
        do {
            if move { try FileManager.default.moveItem(at: source, to: temporary) }
            else { try FileManager.default.copyItem(at: source, to: temporary) }
            guard try FileIntegrity.sha256(temporary) == sourceHash else { throw PureToneError.message("导入文件校验不一致") }
            try FileManager.default.moveItem(at: temporary, to: target)
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
        return try await index(target, hash: sourceHash)
    }
    func rescan() async throws -> [Track] {
        var result: [Track] = []
        for file in regularFiles(in: Paths.music) where ["flac", "mp3"].contains(file.pathExtension.lowercased()) {
            if let t = try await index(file, hash: try FileIntegrity.sha256(file)) { result.append(t) }
        }
        return result
    }
    private func index(_ url: URL, hash: String) async throws -> Track? {
        guard ["flac", "mp3"].contains(url.pathExtension.lowercased()) else { return nil }
        let previous = try db.all(Track.self, kind: "track").first { $0.id == hash }
        guard let decoder = pt_decoder_open_indexed(url.path) else { throw PureToneError.core }
        let info = pt_decoder_info(decoder); pt_decoder_close(decoder)
        let metadata = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
        var values: [String: String] = [:]; var art: Data?
        for item in metadata {
            if let key = item.commonKey?.rawValue, let text = try? await item.load(.stringValue) { values[key] = text }
            if item.commonKey == .commonKeyArtwork { art = try? await item.load(.dataValue) }
        }
        let fullMetadata = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        var trackNumber = 0, discNumber = 0
        for item in fullMetadata {
            let key = item.key.map { String(describing: $0).uppercased() } ?? ""
            if let text = try? await item.load(.stringValue) {
                if key.contains("TRACKNUMBER") || key == "TRCK" { trackNumber = Int(text.split(separator: "/").first ?? "0") ?? 0 }
                if key.contains("DISCNUMBER") || key == "TPOS" { discNumber = Int(text.split(separator: "/").first ?? "0") ?? 0 }
                if key.contains("ALBUMARTIST") || key == "TPE2" { values["albumArtist"] = text }
            }
        }
        if art == nil {
            let directory = url.deletingLastPathComponent()
            let stem = url.deletingPathExtension().lastPathComponent
            for name in [stem, "cover", "folder", "front"] {
                for ext in ["jpg", "jpeg", "png"] {
                    let file = directory.appendingPathComponent(name + "." + ext)
                    guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 20_971_520 else { continue }
                    if let bytes = try? Data(contentsOf: file) { art = bytes; break }
                }
                if art != nil { break }
            }
        }
        var artwork: String?
        if let art { let dest = Paths.artwork.appendingPathComponent(hash + ".jpg"); try art.write(to: dest, options: .atomic); artwork = dest.lastPathComponent }
        let relative = try FileIntegrity.relativePath(url, beneath: Paths.music)
        var track = Track(id: hash, relativePath: relative, title: values["title"] ?? url.deletingPathExtension().lastPathComponent,
                          artist: values["artist"] ?? "未知歌手", album: values["albumName"] ?? url.deletingLastPathComponent().lastPathComponent,
                          duration: info.duration, sampleRate: info.sampleRate, bitDepth: Int(info.bitsPerSample), channels: Int(info.channels), artworkPath: artwork)
        track.favorite = previous?.favorite ?? false; track.added = previous?.added ?? Date(); track.trackNumber = trackNumber; track.discNumber = discNumber
        track.albumArtist = values["albumArtist"] ?? ""
        track = TrackIdentity.resolve(track, tags: (try? AudioFileTags.read(url)) ?? AudioFileTags())
        try db.put(track, kind: "track", id: hash); return track
    }
    func resolveLocalTrack(_ original: Track, candidates: [URL]? = nil) throws -> Track {
        guard let track = try db.get(Track.self, kind: "track", id: original.id) else {
            throw PureToneError.message("歌曲已从曲库移除")
        }
        let file = try FileIntegrity.musicURL(track.relativePath)
        if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return track }
        // Repair a moved file or a legacy truncated relative path only after verifying
        // the original SHA-256. A matching title or filename alone is insufficient.
        if track.id.count == 64, track.id.allSatisfy(\.isHexDigit) {
            let name = file.lastPathComponent
            for candidate in candidates ?? regularFiles(in: Paths.music) {
                try Task.checkCancellation()
                guard candidate.pathExtension.lowercased() == file.pathExtension.lowercased(),
                      candidate.lastPathComponent.hasSuffix(name),
                      let relative = try? FileIntegrity.relativePath(candidate, beneath: Paths.music),
                      (try? FileIntegrity.sha256(candidate)) == track.id.lowercased() else { continue }
                return try db.transaction {
                    guard var latest = try db.get(Track.self, kind: "track", id: track.id) else {
                        throw PureToneError.message("歌曲已从曲库移除")
                    }
                    latest.relativePath = relative
                    try db.put(latest, kind: "track", id: latest.id)
                    return latest
                }
            }
        }
        throw PureToneError.message("找不到本机原文件：Music/\(track.relativePath)\n请在“文件 → 我的 iPad → PureTone → Music”确认文件是否仍在；如已移动，可重新扫描 Music 文件夹。")
    }
    func repairMetadata(_ tracks: [Track]) throws {
        for track in tracks {
            try Task.checkCancellation()
            guard let latest = try db.get(Track.self, kind: "track", id: track.id),
                  let file = try? FileIntegrity.musicURL(latest.relativePath) else { continue }
            let tags = (try? AudioFileTags.read(file)) ?? AudioFileTags()
            try db.transaction {
                // Favorite/deletion operations can occur while tags are read on this actor.
                guard let latest = try db.get(Track.self, kind: "track", id: track.id) else { return }
                let repaired = TrackIdentity.resolve(latest, tags: tags)
                if repaired != latest { try db.put(repaired, kind: "track", id: track.id) }
            }
        }
    }
}

@MainActor @Observable final class LibraryStore {
    let db: Database
    let importer: ImportService
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    var importing = false
    var error: String?
    private var metadataRefreshed = false
    init(database: Database? = nil) {
        do {
            try Paths.prepare()
            if let database { db = database } else { db = try Database(url: Paths.support.appendingPathComponent("Library.sqlite")) }
        }
        catch { fatalError("曲库初始化失败：\(error)") }
        importer = ImportService(db: db)
        reload()
    }
    func reload() {
        do { tracks = try db.all(Track.self, kind: "track").sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }; playlists = try db.all(Playlist.self, kind: "playlist") }
        catch { self.error = error.localizedDescription }
    }
    func importFiles(_ urls: [URL]) async {
        importing = true; defer { importing = false; reload() }
        do { _ = try await importer.importURLs(urls) } catch { self.error = error.localizedDescription }
    }
    func refreshMetadata() async {
        guard !metadataRefreshed else { return }; metadataRefreshed = true
        do { try await importer.repairMetadata(tracks); reload() } catch { self.error = error.localizedDescription }
    }
    func playbackURLs(_ tracks: [Track]) async throws -> [URL] {
        var files: [URL] = []
        for track in tracks {
            try Task.checkCancellation()
            let resolved = try await importer.resolveLocalTrack(track)
            if resolved.relativePath != track.relativePath { reload() }
            files.append(try FileIntegrity.musicURL(resolved.relativePath))
        }
        return files
    }
    func favorite(_ track: Track) {
        var t = track; t.favorite.toggle()
        do { try db.put(t, kind: "track", id: t.id); reload() } catch { self.error = error.localizedDescription }
    }
    func save(_ playlist: Playlist) {
        do { try db.put(playlist, kind: "playlist", id: playlist.id.uuidString); reload() } catch { self.error = error.localizedDescription }
    }
    func addTracks(_ ids: [String], to playlistID: UUID) {
        guard var playlist = playlists.first(where: { $0.id == playlistID }) else { return }
        let available = Set(tracks.map(\.id)); var existing = Set(playlist.trackIDs)
        playlist.trackIDs.append(contentsOf: ids.filter { available.contains($0) && existing.insert($0).inserted })
        save(playlist)
    }
    func removeTracks(_ ids: Set<String>, from playlistID: UUID) {
        guard var playlist = playlists.first(where: { $0.id == playlistID }) else { return }
        playlist.trackIDs.removeAll { ids.contains($0) }; save(playlist)
    }
    func setFavorite(_ ids: Set<String>, value: Bool) {
        do {
            try db.transaction {
                for var track in tracks where ids.contains(track.id) { track.favorite = value; try db.put(track, kind: "track", id: track.id) }
            }
            reload()
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func deleteTracks(_ ids: Set<String>) -> Bool {
        let targets = tracks.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return true }
        let fm = FileManager.default
        let staging = Paths.support.appendingPathComponent("Deletion-\(UUID().uuidString)", isDirectory: true)
        var moved: [(URL, URL)] = []
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let root = Paths.music.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            for track in targets {
                _ = try FileIntegrity.safeRelative(track.relativePath)
                let source = url(track).standardizedFileURL.resolvingSymlinksInPath()
                guard source.path.hasPrefix(root) else { throw PureToneError.message("歌曲路径不在本机 Music 目录内") }
                if fm.fileExists(atPath: source.path) {
                    let temporary = staging.appendingPathComponent(UUID().uuidString)
                    try fm.moveItem(at: source, to: temporary); moved.append((source, temporary))
                }
            }
            try db.transaction {
                for track in targets { try db.remove(kind: "track", id: track.id) }
                for var playlist in playlists {
                    playlist.trackIDs.removeAll { ids.contains($0) }
                    try db.put(playlist, kind: "playlist", id: playlist.id.uuidString)
                }
            }
        } catch {
            var rollbackFailed = false
            for (original, temporary) in moved.reversed() {
                do { try fm.moveItem(at: temporary, to: original) } catch { rollbackFailed = true }
            }
            if !rollbackFailed { try? fm.removeItem(at: staging) }
            self.error = error.localizedDescription + (rollbackFailed ? "；待恢复文件保留在 \(staging.path)" : "")
            return false
        }
        try? fm.removeItem(at: staging)
        for track in targets {
            try? fm.removeItem(at: Paths.lyrics.appendingPathComponent(track.id + ".json"))
            if let art = track.artworkPath { try? fm.removeItem(at: Paths.artwork.appendingPathComponent(art)) }
        }
        reload(); return true
    }
    func url(_ track: Track) -> URL {
        Paths.music.appendingPathComponent(tracks.first { $0.id == track.id }?.relativePath ?? track.relativePath)
    }
}
