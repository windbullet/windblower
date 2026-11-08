import Foundation
import UniformTypeIdentifiers

struct LibraryBackup: Codable {
    struct Record: Codable { var kind: String; var id: String; var payload: Data }
    var version = 1
    var created = Date()
    var records: [Record]
    var lyrics: [String: Data]
}

extension Database {
    func backup() throws -> LibraryBackup {
        var records: [LibraryBackup.Record] = []
        func append<T: Codable>(_ type: T.Type, kind: String, id: (T) -> String) throws {
            for value in try all(type, kind: kind) { records.append(.init(kind: kind, id: id(value), payload: try JSONEncoder().encode(value))) }
        }
        try append(Track.self, kind: "track", id: { $0.id })
        try append(Playlist.self, kind: "playlist", id: { $0.id.uuidString })
        try append(EQConfiguration.self, kind: "eq", id: { _ in "current" })
        try append(EQPreset.self, kind: "preset", id: { $0.id.uuidString })
        try append(RemoteServer.self, kind: "server", id: { $0.id.uuidString })
        var lyrics: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: Paths.lyrics, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            lyrics[file.lastPathComponent] = try Data(contentsOf: file)
        }
        return LibraryBackup(records: records, lyrics: lyrics)
    }
    func restore(_ backup: LibraryBackup) throws {
        guard backup.version == 1 else { throw PureToneError.message("暂不支持此备份版本") }
        for record in backup.records {
            switch record.kind {
            case "track": let value = try JSONDecoder().decode(Track.self, from: record.payload); try put(value, kind: record.kind, id: value.id)
            case "playlist": let value = try JSONDecoder().decode(Playlist.self, from: record.payload); try put(value, kind: record.kind, id: value.id.uuidString)
            case "eq": let value = try JSONDecoder().decode(EQConfiguration.self, from: record.payload); try put(value, kind: record.kind, id: "current")
            case "preset": let value = try JSONDecoder().decode(EQPreset.self, from: record.payload); try put(value, kind: record.kind, id: value.id.uuidString)
            case "server": let value = try JSONDecoder().decode(RemoteServer.self, from: record.payload); try put(value, kind: record.kind, id: value.id.uuidString)
            default: continue
            }
        }
        for (name, data) in backup.lyrics {
            guard name.count == 69, name.hasSuffix(".json"), name.dropLast(5).allSatisfy(\.isHexDigit) else { continue }
            _ = try JSONDecoder().decode(Lyrics.self, from: data)
            try data.write(to: Paths.lyrics.appendingPathComponent(name), options: .atomic)
        }
    }
}
