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
    func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> PureToneError { .message(db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error") }
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
                let root = url.deletingLastPathComponent().path + "/"
                for file in regularFiles(in: url) {
                    if let t = try await ingest(file, relative: String(file.path.dropFirst(root.count)), move: false) { result.append(t) }
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
        guard let decoder = pt_decoder_open(url.path) else { throw PureToneError.core }
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
        let relative = String(url.path.dropFirst(Paths.music.path.count + 1))
        var track = Track(id: hash, relativePath: relative, title: values["title"] ?? url.deletingPathExtension().lastPathComponent,
                          artist: values["artist"] ?? "未知歌手", album: values["albumName"] ?? url.deletingLastPathComponent().lastPathComponent,
                          duration: info.duration, sampleRate: info.sampleRate, bitDepth: Int(info.bitsPerSample), channels: Int(info.channels), artworkPath: artwork)
        track.favorite = previous?.favorite ?? false; track.added = previous?.added ?? Date(); track.trackNumber = trackNumber; track.discNumber = discNumber
        track.albumArtist = values["albumArtist"] ?? ""
        try db.put(track, kind: "track", id: hash); return track
    }
}

@MainActor @Observable final class LibraryStore {
    let db: Database
    let importer: ImportService
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    var importing = false
    var error: String?
    init() {
        do { try Paths.prepare(); db = try Database(url: Paths.support.appendingPathComponent("Library.sqlite")) }
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
    func favorite(_ track: Track) {
        var t = track; t.favorite.toggle()
        do { try db.put(t, kind: "track", id: t.id); reload() } catch { self.error = error.localizedDescription }
    }
    func save(_ playlist: Playlist) {
        do { try db.put(playlist, kind: "playlist", id: playlist.id.uuidString); reload() } catch { self.error = error.localizedDescription }
    }
    func url(_ track: Track) -> URL { Paths.music.appendingPathComponent(track.relativePath) }
}
