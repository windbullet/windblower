import Foundation

struct LyricsSourceResult: Sendable {
    var source: String
    var candidates: [Lyrics] = []
    var detail: String
}

enum LyricsMatching {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func baseTitle(_ text: String) -> String {
        normalize(text.replacingOccurrences(of: #"(?i)[(（\[]\s*cover\s*[)）\]]"#, with: "", options: .regularExpression))
    }
    private static func artistNames(_ text: String) -> Set<String> {
        let separated = text.replacingOccurrences(of: #"(?i)\s+(?:feat\.?|featuring)\s+|\s*[/;&、]\s*"#, with: "|", options: .regularExpression)
        return Set(separated.split(separator: "|").map { normalize(String($0)) }.filter { !$0.isEmpty })
    }
    static func score(_ lyrics: Lyrics, track: Track) -> Double {
        let title = normalize(lyrics.title), target = normalize(TrackIdentity.cleanFilenameTitle(track.title))
        guard !title.isEmpty, !target.isEmpty else { return 0 }
        let aliases = (lyrics.titleAliases ?? []).map(normalize)
        let matched = title == target || aliases.contains(target) || baseTitle(lyrics.title) == baseTitle(TrackIdentity.cleanFilenameTitle(track.title))
        guard matched else { return 0 }
        // An alias may translate a title, but must never erase version information.
        let versions = ["live", "remix", "instrumental", "伴奏", "acoustic", "animever", "tvsize", "shortver", "カラオケ"]
        if versions.contains(where: { title.contains($0) != target.contains($0) }) { return 0 }
        if let duration = lyrics.duration, track.duration > 0, abs(duration - track.duration) > 5 { return 0 }
        let artist = normalize(lyrics.artist), wanted = normalize(track.artist)
        guard !artist.isEmpty, !wanted.isEmpty, wanted != normalize("未知歌手"), wanted != "unknownartist",
              artist == wanted || !artistNames(lyrics.artist).isDisjoint(with: artistNames(track.artist)) else { return 0 }
        return 0.8 + (lyrics.duration == nil ? 0 : 0.1) + (title == target ? 0.05 : 0) +
            (normalize(lyrics.album ?? "") == normalize(track.album) && !track.album.isEmpty ? 0.05 : 0)
    }
    static func ranked(_ values: [Lyrics], track: Track, manual: Bool) -> [Lyrics] {
        values.filter { !$0.lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && (manual || score($0, track: track) >= 0.8) }
            .sorted {
                // Once identity/version/duration pass, prefer real word timing.
                if $0.quality != $1.quality { return $0.quality > $1.quality }
                return score($0, track: track) > score($1, track: track)
            }
    }
}

actor LyricsService {
    private let session: URLSession
    private var blockedUntil: [String: Date] = [:]
    static let sources = ["网易云", "酷狗", "QQ 音乐", "LRCLIB"]
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 16
            config.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(configuration: config)
        }
    }
    private func json(_ url: URL, body: [String: Any]? = nil) async throws -> Any {
        try Task.checkCancellation()
        guard blockedUntil[url.host ?? "", default: .distantPast] < Date() else { throw PureToneError.message("限流中，请稍后重试") }
        var request = URLRequest(url: url)
        request.setValue("PureTone/0.4.0 (https://github.com/windbullet/windblower)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if url.host == "music.163.com" { request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer") }
        if url.host?.hasSuffix("qq.com") == true { request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer") }
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw PureToneError.message("响应无效") }
        if http.statusCode == 429 || http.statusCode == 503 {
            let delay = min(3_600, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60))
            blockedUntil[url.host ?? ""] = Date().addingTimeInterval(delay)
        }
        guard (200..<300).contains(http.statusCode) else { throw PureToneError.message("HTTP \(http.statusCode)") }
        guard data.count <= 8_388_608 else { throw PureToneError.message("响应过大") }
        return try JSONSerialization.jsonObject(with: data)
    }
    private func object(_ url: URL, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let result = try await json(url, body: body) as? [String: Any] else { throw PureToneError.message("响应格式无效") }
        return result
    }
    private func url(_ base: String, _ query: [String: String]) -> URL {
        var parts = URLComponents(string: base)!
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }
    func source(_ source: String, track: Track, keyword: String? = nil) async -> LyricsSourceResult {
        do {
            let candidates: [Lyrics]
            switch source {
            case "网易云": candidates = try await netease(track, keyword: keyword)
            case "酷狗": candidates = try await kugou(track, keyword: keyword)
            case "QQ 音乐": candidates = try await qq(track, keyword: keyword)
            default: candidates = try await lrclib(track, keyword: keyword)
            }
            let values = LyricsMatching.ranked(candidates, track: track, manual: keyword != nil)
            return LyricsSourceResult(source: source, candidates: values, detail: values.isEmpty ? "未找到可用且匹配版本的歌词" : "找到 \(values.count) 份歌词")
        } catch {
            return LyricsSourceResult(source: source, detail: error.localizedDescription)
        }
    }
    func search(track: Track, keyword: String? = nil) async -> [Lyrics] {
        await withTaskGroup(of: LyricsSourceResult.self) { group in
            for name in Self.sources { group.addTask { await self.source(name, track: track, keyword: keyword) } }
            var values: [Lyrics] = []
            for await result in group { values.append(contentsOf: result.candidates) }
            return LyricsMatching.ranked(values, track: track, manual: keyword != nil)
        }
    }
    private func eligible(_ lyrics: Lyrics, track: Track, keyword: String?) -> Bool { keyword != nil || LyricsMatching.score(lyrics, track: track) >= 0.8 }
    private func lrclibValue(_ value: [String: Any]) -> Lyrics? {
        var lines: [LyricLine] = []
        if let yaml = value["lyricsfile"] as? String, let parsed = try? LyricsParser.lyricsfile(yaml), !parsed.isEmpty { lines = parsed }
        if lines.isEmpty, let lrc = value["syncedLyrics"] as? String, !lrc.isEmpty { lines = LyricsParser.lrc(lrc) }
        if lines.isEmpty, let plain = value["plainLyrics"] as? String, !plain.isEmpty { lines = LyricsParser.plain(plain) }
        guard !lines.isEmpty else { return nil }
        return Lyrics(source: "LRCLIB", title: value["trackName"] as? String ?? "", artist: value["artistName"] as? String ?? "",
                      duration: (value["duration"] as? NSNumber)?.doubleValue, lines: lines, album: value["albumName"] as? String)
    }
    private func lrclib(_ track: Track, keyword: String?) async throws -> [Lyrics] {
        if keyword == nil {
            // Album spelling varies by release; exact duration/title/artist do not need it.
            let endpoint = url("https://lrclib.net/api/get", ["track_name": track.title, "artist_name": track.artist, "duration": String(Int(track.duration.rounded()))])
            if let value = try? await object(endpoint), let lyrics = lrclibValue(value) { return [lyrics] }
        }
        let endpoint = url("https://lrclib.net/api/search", ["q": keyword ?? "\(track.artist) \(track.title)"])
        guard let values = try await json(endpoint) as? [[String: Any]] else { throw PureToneError.message("搜索响应格式无效") }
        return values.prefix(12).compactMap(lrclibValue)
    }
    private func netease(_ track: Track, keyword: String?) async throws -> [Lyrics] {
        let search = try await object(url("https://music.163.com/api/search/get", ["s": keyword ?? "\(track.artist) \(track.title)", "type": "1", "limit": "10"]))
        if let code = search["code"] as? Int, code != 200 { throw PureToneError.message("搜索服务返回 \(code)") }
        let songs = (search["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
        var result: [Lyrics] = []; var lastFailure: Error?
        var downloads = 0
        for song in songs {
            guard let id = song["id"] as? NSNumber else { continue }
            let artists = (song["artists"] as? [[String: Any]] ?? song["ar"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            let duration = ((song["duration"] ?? song["dt"]) as? NSNumber).map { $0.doubleValue / 1000 }
            var lyrics = Lyrics(source: "网易云", title: song["name"] as? String ?? "", artist: artists, duration: duration, lines: [],
                                album: (song["album"] as? [String: Any])?["name"] as? String,
                                titleAliases: (song["alias"] as? [String] ?? []) + (song["transNames"] as? [String] ?? []))
            guard eligible(lyrics, track: track, keyword: keyword) else { continue }
            downloads += 1; if downloads > 3 { break }
            // A bad or empty candidate must not discard another successfully decoded candidate.
            let response: [String: Any]
            do { response = try await object(url("https://music.163.com/api/song/lyric/v1", ["id": id.stringValue, "lv": "-1", "tv": "-1", "rv": "-1", "yv": "-1"])) }
            catch { lastFailure = error; continue }
            if let yrc = (response["yrc"] as? [String: Any])?["lyric"] as? String, !yrc.isEmpty { lyrics.lines = LyricsParser.timed(yrc, format: "yrc") }
            else if let lrc = (response["lrc"] as? [String: Any])?["lyric"] as? String, !lrc.isEmpty { lyrics.lines = LyricsParser.lrc(lrc) }
            if !lyrics.lines.isEmpty { result.append(lyrics) }
        }
        if result.isEmpty, let lastFailure { throw lastFailure }
        return result
    }
    private func kugou(_ track: Track, keyword: String?) async throws -> [Lyrics] {
        let value = try await object(url("https://lyrics.kugou.com/search", ["ver": "1", "man": "no", "client": "pc", "keyword": keyword ?? "\(track.artist) - \(track.title)", "duration": String(Int(track.duration * 1000))]))
        var result: [Lyrics] = []; var lastFailure: Error?
        for candidate in (value["candidates"] as? [[String: Any]] ?? []).prefix(6) {
            guard let id = candidate["id"], let key = candidate["accesskey"] as? String else { continue }
            var lyrics = Lyrics(source: "酷狗", title: candidate["song"] as? String ?? "", artist: candidate["singer"] as? String ?? "", duration: (candidate["duration"] as? NSNumber).map { $0.doubleValue / 1000 }, lines: [])
            guard eligible(lyrics, track: track, keyword: keyword) else { continue }
            do {
                let download = try await object(url("https://lyrics.kugou.com/download", ["ver": "1", "client": "pc", "id": String(describing: id), "accesskey": key, "fmt": "krc", "charset": "utf8"]))
                guard let content = download["content"] as? String, let data = Data(base64Encoded: content) else { throw PureToneError.message("下载未返回有效歌词数据") }
                lyrics.lines = LyricsParser.timed(try LyricsCipher.krc(data), format: "krc"); result.append(lyrics)
            } catch { lastFailure = error; continue }
            if result.count >= 3 { break }
        }
        if result.isEmpty, let lastFailure { throw lastFailure }
        return result
    }
    private func qq(_ track: Track, keyword: String?) async throws -> [Lyrics] {
        let searchBody: [String: Any] = ["comm": ["ct": 19, "cv": 1859], "request": ["method": "DoSearchForQQMusicDesktop", "module": "music.search.SearchCgiService", "param": ["query": keyword ?? "\(track.artist) \(track.title)", "num_per_page": 10, "page_num": 1, "search_type": 0]]]
        let search = try await object(URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, body: searchBody)
        let request = search["request"] as? [String: Any] ?? [:]
        if let code = request["code"] as? Int, code != 0 { throw PureToneError.message("搜索服务返回 \(code)") }
        let data = request["data"] as? [String: Any]
        let songs = ((data?["body"] as? [String: Any])?["song"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        var result: [Lyrics] = []; var downloads = 0; var lastFailure: Error?
        for song in songs {
            guard let id = song["id"] as? NSNumber else { continue }
            let artist = (song["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            var lyrics = Lyrics(source: "QQ 音乐", title: song["title"] as? String ?? "", artist: artist, duration: (song["interval"] as? NSNumber)?.doubleValue, lines: [], album: (song["album"] as? [String: Any])?["name"] as? String)
            guard eligible(lyrics, track: track, keyword: keyword) else { continue }
            downloads += 1; if downloads > 3 { break }
            func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
            let params: [String: Any] = ["songID": id, "songName": b64(lyrics.title), "singerName": b64(artist), "albumName": b64(lyrics.album ?? track.album), "interval": Int(lyrics.duration ?? track.duration), "crypt": 1, "qrc": 1, "qrc_t": 0, "lrc_t": 0, "trans": 0, "roma": 0, "ct": 19, "cv": 2111, "type": 0]
            do {
                let value = try await object(URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, body: ["comm": ["ct": 19, "cv": 1859], "request": ["method": "GetPlayLyricInfo", "module": "music.musichallSong.PlayLyricInfo", "param": params]])
                guard let data = (value["request"] as? [String: Any])?["data"] as? [String: Any], let content = data["lyric"] as? String, !content.isEmpty else { continue }
                lyrics.lines = LyricsParser.timed(try LyricsCipher.qrc(content), format: "qrc"); result.append(lyrics)
            } catch { lastFailure = error; continue }
        }
        if result.isEmpty, let lastFailure { throw lastFailure }
        return result
    }
}
