import Foundation
import Observation
import Yams

struct LyricWord: Codable, Hashable, Sendable { var text: String; var start: Double; var end: Double }
struct LyricLine: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var text: String
    var start: Double?
    var end: Double?
    var words: [LyricWord] = []
}
struct Lyrics: Codable, Identifiable, Sendable {
    var id = UUID()
    var source: String
    var title: String
    var artist: String
    var duration: Double?
    var lines: [LyricLine]
    var offset: Double = 0
    var pinned = false
    var quality: Int { lines.contains { !$0.words.isEmpty } ? 2 : (lines.contains { $0.start != nil } ? 1 : 0) }
    var qualityName: String { ["纯文本", "逐行", "逐字"][quality] }
}

enum LyricsParser {
    static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }
    static func lrc(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let offset = matches(#"\[offset:([+-]?\d+)\]"#, text).first.flatMap { Double($0[1]) }.map { $0 / 1000 } ?? 0
        for raw in text.components(separatedBy: .newlines) {
            let stamps = matches(#"\[(\d+):(\d+(?:\.\d+)?)\]"#, raw)
            let content = raw.replacingOccurrences(of: #"\[(?:\d+:\d+(?:\.\d+)?|[A-Za-z]+:[^\]]*)\]"#, with: "", options: .regularExpression)
            guard !stamps.isEmpty else { continue }
            let wordMatches = matches(#"<(\d+):(\d+(?:\.\d+)?)>([^<]*)"#, content)
            var words = wordMatches.map { LyricWord(text: $0[3], start: (Double($0[1]) ?? 0) * 60 + (Double($0[2]) ?? 0) + offset, end: 0) }
            for i in words.indices { words[i].end = i + 1 < words.count ? words[i + 1].start : words[i].start }
            for stamp in stamps {
                let start = (Double(stamp[1]) ?? 0) * 60 + (Double(stamp[2]) ?? 0) + offset
                lines.append(LyricLine(text: words.isEmpty ? content : words.map(\.text).joined(), start: start, end: nil, words: words))
            }
        }
        lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        for i in lines.indices where i + 1 < lines.count {
            lines[i].end = lines[i + 1].start
            if !lines[i].words.isEmpty { lines[i].words[lines[i].words.count - 1].end = lines[i + 1].start ?? lines[i].words.last!.start }
        }
        return lines.isEmpty ? plain(text) : lines
    }
    static func plain(_ text: String) -> [LyricLine] { text.components(separatedBy: .newlines).map { LyricLine(text: $0, start: nil, end: nil) } }
    static func timed(_ text: String, format: String) -> [LyricLine] {
        let content: String
        if format == "qrc", let value = matches(#"LyricContent="(.*?)""#, text).first?[1] {
            content = value.replacingOccurrences(of: "&#10;", with: "\n").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        } else { content = text }
        var result: [LyricLine] = []
        for raw in content.components(separatedBy: .newlines) {
            guard let line = matches(#"^\[(\d+),(\d+)\](.*)$"#, raw).first, let startMS = Double(line[1]), let durationMS = Double(line[2]) else { continue }
            let pattern = format == "krc" ? #"<(\d+),(\d+),\d+>(.*?)(?=<\d+,\d+,\d+>|$)"#
                : (format == "qrc" ? #"(.*?)\((\d+),(\d+)\)"# : #"\((\d+),(\d+),\d+\)(.*?)(?=\(\d+,\d+,\d+\)|$)"#)
            let words = matches(pattern, line[3]).compactMap { m -> LyricWord? in
                let timeIndex = format == "qrc" ? 2 : 1, durationIndex = format == "qrc" ? 3 : 2, textIndex = format == "qrc" ? 1 : 3
                guard let t = Double(m[timeIndex]), let d = Double(m[durationIndex]), d >= 0 else { return nil }
                let start = (t + (format == "krc" ? startMS : 0)) / 1000
                return LyricWord(text: m[textIndex], start: start, end: start + d / 1000)
            }
            result.append(LyricLine(text: words.isEmpty ? line[3] : words.map(\.text).joined(), start: startMS / 1000, end: (startMS + durationMS) / 1000, words: words))
        }
        return result.isEmpty ? lrc(content) : result
    }
    static func lyricsfile(_ yaml: String) throws -> [LyricLine] {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any], let lines = root["lines"] as? [[String: Any]] else { throw PureToneError.message("无效的 Lyricsfile") }
        func seconds(_ value: Any?) -> Double? { (value as? NSNumber).map { $0.doubleValue / 1000 } }
        return lines.map { line in
            let words = (line["words"] as? [[String: Any]] ?? []).compactMap { word -> LyricWord? in
                guard let text = word["text"] as? String, let start = seconds(word["start_ms"] ?? word["start"]), let end = seconds(word["end_ms"] ?? word["end"]), end >= start else { return nil }
                return LyricWord(text: text, start: start, end: end)
            }
            return LyricLine(text: line["text"] as? String ?? words.map(\.text).joined(), start: seconds(line["start_ms"] ?? line["start"]), end: seconds(line["end_ms"] ?? line["end"]), words: words)
        }
    }
}

actor LyricsService {
    private let session: URLSession
    private var blockedUntil: [String: Date] = [:]
    init() {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 12
        session = URLSession(configuration: config)
    }
    private func json(_ url: URL, body: Any? = nil, headers: [String: String] = [:]) async throws -> [String: Any] {
        guard blockedUntil[url.host ?? "", default: .distantPast] < Date() else { throw PureToneError.message("歌词源限流中") }
        var request = URLRequest(url: url)
        request.setValue("PureTone/0.1 (https://github.com/topics/puretone)", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PureToneError.message("歌词响应无效") }
        if http.statusCode == 429 || http.statusCode == 503 {
            let delay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
            blockedUntil[url.host ?? ""] = Date().addingTimeInterval(delay + Double.random(in: 0...max(1, delay * 0.2)))
        }
        guard (200..<300).contains(http.statusCode) else { throw PureToneError.message("歌词源 HTTP \(http.statusCode)") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PureToneError.message("歌词响应格式无效") }
        return object
    }
    private func url(_ base: String, _ query: [String: String]) -> URL {
        var components = URLComponents(string: base)!; components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }; return components.url!
    }
    func search(track: Track, keyword: String? = nil) async -> [Lyrics] {
        var result: [Lyrics] = []
        // Bounded source requests. Failure of one provider never blocks the others or playback.
        async let netease = try? netease(track, keyword: keyword)
        async let kugou = try? kugou(track, keyword: keyword)
        async let qq = try? qq(track, keyword: keyword)
        async let lrc = try? lrclib(track, keyword: keyword)
        for value in await [netease, kugou, qq, lrc] { result.append(contentsOf: value ?? []) }
        return result.sorted {
            let a = match($0, track: track), b = match($1, track: track)
            return a == b ? $0.quality > $1.quality : a > b
        }.filter { match($0, track: track) >= 0.65 }
    }
    private func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private func match(_ lyrics: Lyrics, track: Track) -> Double {
        let title = normalize(lyrics.title), target = normalize(track.title)
        guard !title.isEmpty, title == target || title.contains(target) || target.contains(title) else { return 0 }
        let versionTerms = ["live", "remix", "伴奏", "instrumental", "acoustic"]
        if versionTerms.contains(where: { title.contains($0) != target.contains($0) }) { return 0 }
        if let duration = lyrics.duration, abs(duration - track.duration) > 5 { return 0 }
        let artist = normalize(lyrics.artist), wanted = normalize(track.artist)
        return (title == target ? 0.65 : 0.4) + (artist == wanted ? 0.3 : (artist.contains(wanted) || wanted.contains(artist) ? 0.15 : 0)) + (lyrics.duration == nil ? 0 : 0.05)
    }
    private func lrclib(_ track: Track, keyword: String?) async throws -> [Lyrics] {
        let endpoint = url("https://lrclib.net/api/get", ["track_name": keyword ?? track.title, "artist_name": track.artist, "album_name": track.album, "duration": String(Int(track.duration.rounded()))])
        let value = try await json(endpoint)
        let lines: [LyricLine]
        if let yaml = value["lyricsfile"] as? String, let parsed = try? LyricsParser.lyricsfile(yaml), !parsed.isEmpty { lines = parsed }
        else if let lrc = value["syncedLyrics"] as? String, !lrc.isEmpty { lines = LyricsParser.lrc(lrc) }
        else { lines = LyricsParser.plain(value["plainLyrics"] as? String ?? "暂无歌词") }
        return [Lyrics(source: "LRCLIB", title: value["trackName"] as? String ?? track.title, artist: value["artistName"] as? String ?? track.artist, duration: (value["duration"] as? NSNumber)?.doubleValue, lines: lines)]
    }
    private func netease(_ track: Track, keyword: String?) async throws -> [Lyrics] {
        let search = try await json(url("https://music.163.com/api/search/get", ["s": keyword ?? "\(track.artist) \(track.title)", "type": "1", "limit": "5"]))
        let songs = (search["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
        var result: [Lyrics] = []
        for song in songs.prefix(3) {
            guard let id = song["id"] as? NSNumber else { continue }
            let title = song["name"] as? String ?? ""
            let artists = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            let duration = (song["duration"] as? NSNumber).map { $0.doubleValue / 1000 }
            var lyrics = Lyrics(source: "网易云", title: title, artist: artists, duration: duration, lines: [])
            guard match(lyrics, track: track) >= 0.65 else { continue }
            let response = try await json(url("https://music.163.com/api/song/lyric/v1", ["id": id.stringValue, "lv": "-1", "tv": "-1", "rv": "-1", "yv": "-1"]))
            if let yrc = (response["yrc"] as? [String: Any])?["lyric"] as? String, !yrc.isEmpty { lyrics.lines = LyricsParser.timed(yrc, format: "yrc") }
            else if let lrc = (response["lrc"] as? [String: Any])?["lyric"] as? String { lyrics.lines = LyricsParser.lrc(lrc) }
            if !lyrics.lines.isEmpty { result.append(lyrics) }
        }
        return result
    }
    private func kugou(_ track: Track, keyword: String?) async throws -> [Lyrics] {
        let value = try await json(url("https://lyrics.kugou.com/search", ["ver": "1", "man": "no", "client": "pc", "keyword": keyword ?? "\(track.artist) - \(track.title)", "duration": String(Int(track.duration * 1000))]))
        var result: [Lyrics] = []
        for candidate in (value["candidates"] as? [[String: Any]] ?? []).prefix(3) {
            guard let id = candidate["id"], let key = candidate["accesskey"] as? String else { continue }
            var lyrics = Lyrics(source: "酷狗", title: candidate["song"] as? String ?? track.title, artist: candidate["singer"] as? String ?? track.artist, duration: (candidate["duration"] as? NSNumber).map { $0.doubleValue / 1000 }, lines: [])
            guard match(lyrics, track: track) >= 0.65 else { continue }
            let download = try await json(url("https://lyrics.kugou.com/download", ["ver": "1", "client": "pc", "id": String(describing: id), "accesskey": key, "fmt": "krc", "charset": "utf8"]))
            if let content = download["content"] as? String, let data = Data(base64Encoded: content) {
                lyrics.lines = LyricsParser.timed(try LyricsCipher.krc(data), format: "krc"); result.append(lyrics)
            }
        }
        return result
    }
    private func qq(_ track: Track, keyword: String?) async throws -> [Lyrics] {
        let searchBody: [String: Any] = ["comm": ["ct": 19, "cv": 1859], "request": ["method": "DoSearchForQQMusicDesktop", "module": "music.search.SearchCgiService", "param": ["query": keyword ?? "\(track.artist) \(track.title)", "num_per_page": 5, "page_num": 1, "search_type": 0]]]
        let search = try await json(URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, body: searchBody)
        let root = (search["request"] as? [String: Any])?["data"] as? [String: Any]
        let body = root?["body"] as? [String: Any]
        let songs = (body?["song"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        var result: [Lyrics] = []
        for song in songs.prefix(3) {
            guard let id = song["id"] as? NSNumber else { continue }
            let artist = (song["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            var lyrics = Lyrics(source: "QQ 音乐", title: song["title"] as? String ?? "", artist: artist, duration: (song["interval"] as? NSNumber)?.doubleValue, lines: [])
            guard match(lyrics, track: track) >= 0.65 else { continue }
            func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
            let params: [String: Any] = ["songID": id, "songName": b64(lyrics.title), "singerName": b64(artist), "albumName": b64((song["album"] as? [String: Any])?["name"] as? String ?? track.album), "interval": Int(lyrics.duration ?? track.duration), "crypt": 1, "qrc": 1, "qrc_t": 0, "lrc_t": 0, "trans": 0, "roma": 0, "ct": 19, "cv": 2111, "type": 0]
            let value = try await json(URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, body: ["comm": ["ct": 19, "cv": 1859], "request": ["method": "GetPlayLyricInfo", "module": "music.musichallSong.PlayLyricInfo", "param": params]])
            if let data = (value["request"] as? [String: Any])?["data"] as? [String: Any], let content = data["lyric"] as? String, !content.isEmpty {
                let decoded = try LyricsCipher.qrc(content); lyrics.lines = LyricsParser.timed(decoded, format: "qrc"); result.append(lyrics)
            }
        }
        return result
    }
}

@MainActor @Observable final class LyricsController {
    var current: Lyrics?
    var candidates: [Lyrics] = []
    var loading = false
    var message = ""
    private let service = LyricsService()
    private var task: Task<Void, Never>?
    private var hash: String?
    func load(_ track: Track, keyword: String? = nil) {
        task?.cancel(); hash = track.id; current = nil; candidates = []; loading = true
        task = Task {
            defer { if !Task.isCancelled { loading = false } }
            let cache = Paths.lyrics.appendingPathComponent(track.id + ".json")
            if keyword == nil, let data = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode(Lyrics.self, from: data) {
                current = saved; if saved.pinned { return }
            }
            if keyword == nil {
                let stem = Paths.music.appendingPathComponent(track.relativePath).deletingPathExtension()
                for ext in ["yrc", "qrc", "krc", "lrc", "txt"] {
                    let file = stem.appendingPathExtension(ext)
                    guard let data = try? Data(contentsOf: file) else { continue }
                    let decoded = String(data: data, encoding: .utf8)
                    let text = (ext == "krc" ? try? LyricsCipher.krc(data) : nil)
                        ?? (ext == "qrc" ? decoded.flatMap { try? LyricsCipher.qrc($0) } : nil)
                        ?? decoded ?? ""
                    let lines = ["krc", "yrc", "qrc"].contains(ext) ? LyricsParser.timed(text, format: ext) : LyricsParser.lrc(text)
                    let local = Lyrics(source: "本地歌词", title: track.title, artist: track.artist, duration: track.duration, lines: lines)
                    if current == nil || local.quality > (current?.quality ?? -1) { current = local }
                }
            }
            let found = await service.search(track: track, keyword: keyword)
            guard !Task.isCancelled, hash == track.id else { return }
            candidates = found
            if let best = found.first, current == nil || best.quality > (current?.quality ?? -1) { current = best; save() }
            message = current == nil ? "未找到匹配歌词，可手动搜索或导入" : ""
        }
    }
    func select(_ lyrics: Lyrics) { current = lyrics; current?.pinned = true; save() }
    func offset(_ value: Double) { current?.offset = value; save() }
    func save() {
        guard let current, let hash else { return }
        if let data = try? JSONEncoder().encode(current) { try? data.write(to: Paths.lyrics.appendingPathComponent(hash + ".json"), options: .atomic) }
    }
}
