import Foundation

// Read only FLAC's UTF-8 Vorbis comments. No decoding, tag rewriting, or picture allocation.
struct AudioFileTags: Sendable {
    var values: [String: [String]] = [:]
    func text(_ key: String) -> String? {
        let text = values[key.uppercased()]?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " / ")
        return text?.isEmpty == false ? text : nil
    }
    static func read(_ url: URL) throws -> AudioFileTags {
        guard url.pathExtension.lowercased() == "flac" else { return AudioFileTags() }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("fLaC".utf8) else { return AudioFileTags() }
        for _ in 0..<128 {
            guard let header = try file.read(upToCount: 4), header.count == 4 else { break }
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            if header[0] & 0x7f == 4 {
                guard length <= 8_388_608, let data = try file.read(upToCount: length), data.count == length else { return AudioFileTags() }
                return try comments(data)
            }
            if header[0] & 0x80 != 0 { break }
            try file.seek(toOffset: file.offset() + UInt64(length))
        }
        return AudioFileTags()
    }
    static func comments(_ data: Data) throws -> AudioFileTags {
        var cursor = 0
        func integer() throws -> Int {
            guard cursor + 4 <= data.count else { throw PureToneError.message("FLAC 标签长度无效") }
            let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[cursor + $1]) << ($1 * 8) }
            cursor += 4; return Int(value)
        }
        func string() throws -> String {
            let size = try integer()
            guard size <= data.count - cursor else { throw PureToneError.message("FLAC 标签内容不完整") }
            defer { cursor += size }
            return String(decoding: data[cursor..<cursor + size], as: UTF8.self)
        }
        _ = try string() // vendor
        let count = try integer()
        guard count <= 65_536 else { throw PureToneError.message("FLAC 标签数量过多") }
        var tags = AudioFileTags()
        for _ in 0..<count {
            let entry = try string()
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<equals].uppercased()
            tags.values[key, default: []].append(String(entry[entry.index(after: equals)...]))
        }
        return tags
    }
}

enum TrackIdentity {
    static func cleanFilenameTitle(_ value: String) -> String {
        value.replacingOccurrences(of: #"^\s*\d{1,3}\s*[.\-、_]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+\d{6,12}$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func resolve(_ original: Track, tags: AudioFileTags = AudioFileTags()) -> Track {
        var track = original
        let fileTitle = URL(fileURLWithPath: track.relativePath).deletingPathExtension().lastPathComponent
        track.title = tags.text("TITLE") ?? cleanFilenameTitle(track.title.isEmpty ? fileTitle : track.title)
        let parts = track.relativePath.split(separator: "/").map(String.init)
        let fallbackArtist = parts.count >= 3 ? parts[parts.count - 3] : ""
        if let artist = tags.text("ARTIST") { track.artist = artist }
        else if ["", "未知歌手", "unknown artist"].contains(track.artist.lowercased()), !fallbackArtist.isEmpty { track.artist = fallbackArtist }
        track.album = tags.text("ALBUM") ?? track.album
        track.albumArtist = tags.text("ALBUMARTIST") ?? tags.text("ALBUM ARTIST") ?? track.albumArtist
        if let value = tags.text("TRACKNUMBER")?.split(separator: "/").first, let number = Int(value) { track.trackNumber = number }
        if let value = tags.text("DISCNUMBER")?.split(separator: "/").first, let number = Int(value) { track.discNumber = number }
        return track
    }
}
