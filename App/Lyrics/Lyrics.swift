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
    var album: String? = nil
    var titleAliases: [String]? = nil
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

@MainActor @Observable final class LyricsController {
    var current: Lyrics?
    var candidates: [Lyrics] = []
    var loading = false
    var message = ""
    var sourceReports: [LyricsSourceResult] = []
    private let service: LyricsService
    private var task: Task<Void, Never>?
    private var hash: String?
    private var generation = UUID()
    init(service: LyricsService = LyricsService()) { self.service = service }
    func load(_ original: Track, keyword: String? = nil, force: Bool = false) {
        if !force, keyword == nil, hash == original.id, loading || current != nil { return }
        let sameTrack = hash == original.id
        task?.cancel(); hash = original.id; generation = UUID(); let ticket = generation
        if !sameTrack || force { current = nil }
        candidates = []; sourceReports = []; loading = true; message = "正在搜索歌词…"
        task = Task {
            defer { if ticket == generation { loading = false } }
            let file = Paths.music.appendingPathComponent(original.relativePath)
            let tags = await Task.detached { (try? AudioFileTags.read(file)) ?? AudioFileTags() }.value
            guard !Task.isCancelled, ticket == generation else { return }
            let track = TrackIdentity.resolve(original, tags: tags)
            let cache = Paths.lyrics.appendingPathComponent(track.id + ".json")
            if keyword == nil, !force, let data = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode(Lyrics.self, from: data) {
                // Old automatic caches may have been bound from incomplete metadata.
                if saved.pinned || LyricsMatching.score(saved, track: track) >= 0.8 || saved.source.contains("本地") {
                    current = saved; if saved.pinned { message = ""; return }
                }
            }
            if keyword == nil {
                if let embedded = tags.text("LYRICS") ?? tags.text("UNSYNCEDLYRICS"), !embedded.isEmpty {
                    let local = Lyrics(source: "本地内嵌歌词", title: track.title, artist: track.artist, duration: track.duration, lines: LyricsParser.lrc(embedded))
                    if current == nil || local.quality > (current?.quality ?? -1) { current = local; save() }
                }
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
                    if !lines.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), current == nil || local.quality > (current?.quality ?? -1) { current = local; save() }
                }
            }
            let query = keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
            let service = self.service
            await withTaskGroup(of: LyricsSourceResult.self) { group in
                for name in LyricsService.sources { group.addTask { await service.source(name, track: track, keyword: query) } }
                for await result in group {
                    guard !Task.isCancelled, ticket == generation else { group.cancelAll(); return }
                    sourceReports.append(result)
                    candidates = LyricsMatching.ranked(candidates + result.candidates, track: track, manual: keyword != nil)
                    if keyword == nil, current?.pinned != true, let best = candidates.first,
                       current == nil || best.quality > (current?.quality ?? -1) {
                        current = best; save()
                    }
                    if keyword != nil { message = candidates.isEmpty ? "正在搜索其他歌词源…" : "找到 \(candidates.count) 份歌词，请从候选结果中选择" }
                    else if current != nil { message = "" }
                }
            }
            guard !Task.isCancelled, ticket == generation else { return }
            if current == nil || keyword != nil && candidates.isEmpty {
                message = "未找到匹配歌词。可修改歌手和歌名后手动搜索，或查看各源结果。"
            }
        }
    }
    func select(_ lyrics: Lyrics) { task?.cancel(); generation = UUID(); loading = false; current = lyrics; current?.pinned = true; message = ""; save() }
    func offset(_ value: Double) { current?.offset = value; save() }
    func save() {
        guard let current, let hash else { return }
        if let data = try? JSONEncoder().encode(current) { try? data.write(to: Paths.lyrics.appendingPathComponent(hash + ".json"), options: .atomic) }
    }
}
