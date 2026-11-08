import Foundation

enum FilterKind: Int, Codable, CaseIterable, Identifiable, Sendable {
    case bell, lowShelf, highShelf, lowPass, highPass, bandPass, notch
    var id: Int { rawValue }
    var title: String { ["峰值", "低搁架", "高搁架", "低通", "高通", "带通", "陷波"][rawValue] }
    var hasGain: Bool { rawValue < 3 }
}

struct EQBand: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: FilterKind = .bell
    var enabled = true
    var frequency: Double
    var q: Double = 0.7071067811865476
    var gain: Double = 0
}

struct EQConfiguration: Codable, Hashable, Sendable {
    var enabled = false
    var preamp: Double = 0
    var bands: [EQBand] = [31.0, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000].map { EQBand(frequency: $0) }

    func native(rate: Double, preamp override: Double? = nil) -> PTEQ {
        var result = pt_eq_default()
        result.enabled = enabled ? 1 : 0
        result.count = Int32(min(32, max(1, bands.count)))
        result.preampDB = override ?? preamp
        withUnsafeMutableBytes(of: &result.bands) { raw in
            let buffer = raw.bindMemory(to: PTBand.self)
            for (i, band) in bands.prefix(32).enumerated() {
                buffer[i] = PTBand(type: Int32(band.kind.rawValue), enabled: band.enabled ? 1 : 0,
                                   frequency: min(max(10, band.frequency), min(20_000, rate * 0.498)),
                                   q: min(30, max(0.1, band.q)), gainDB: min(24, max(-24, band.gain)))
            }
        }
        return result
    }

    func response(at frequency: Double, rate: Double, effectivePreamp: Double? = nil) -> Double {
        var eq = native(rate: rate, preamp: effectivePreamp)
        return pt_eq_response_db(&eq, rate, frequency)
    }
}

struct EQPreset: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var configuration: EQConfiguration
}

struct Track: Codable, Identifiable, Hashable, Sendable {
    var id: String // Original file SHA-256.
    var relativePath: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String = ""
    var trackNumber = 0
    var discNumber = 0
    var duration: Double
    var sampleRate: Double
    var bitDepth: Int
    var channels: Int
    var favorite = false
    var artworkPath: String?
    var added = Date()
    var format: String { URL(fileURLWithPath: relativePath).pathExtension.uppercased() }
    var folder: String { (relativePath as NSString).deletingLastPathComponent }
}

struct Playlist: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var trackIDs: [String] = []
}

enum RepeatMode: String, Codable, CaseIterable { case off, all, one }

struct PeakReport: Codable, Sendable {
    var samplePeak: Double
    var truePeak: Double
    var inputPeak: Double
    var effectivePreamp: Double
    var safety: Double
    init(_ result: PTAnalysis) {
        samplePeak = result.samplePeak; truePeak = result.truePeak; inputPeak = result.inputPeak
        effectivePreamp = result.effectivePreampDB; safety = result.safetyDB
    }
}

struct SignalPath: Sendable {
    var sourceRate: Double = 0
    var outputRate: Double = 0
    var sessionMode = "尚未激活"
    var route = "未连接"
    var outputLatency: Double = 0
    var bufferDuration: Double = 0
    var effectivePreamp: Double = 0
    var safety: Double = 0
    var underruns: UInt64 = 0
    var resampling: Bool { sourceRate > 0 && sourceRate != outputRate }
}

enum PureToneError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
    static var core: Self { .message(String(cString: pt_last_error())) }
}

enum Paths {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PureTone", isDirectory: true)
    static let music = documents.appendingPathComponent("Music", isDirectory: true)
    static let uploads = support.appendingPathComponent("Uploads", isDirectory: true)
    static let lyrics = support.appendingPathComponent("Lyrics", isDirectory: true)
    static let artwork = support.appendingPathComponent("Artwork", isDirectory: true)
    static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Originals", isDirectory: true)
    static func prepare() throws {
        for url in [support, music, uploads, lyrics, artwork, cache] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
    }
}
