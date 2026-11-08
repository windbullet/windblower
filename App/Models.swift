import Foundation

enum FilterKind: Int, Codable, CaseIterable, Identifiable, Sendable {
    case bell, lowShelf, highShelf, lowPass, highPass, bandPass, notch
    var id: Int { rawValue }
    var title: String { ["峰值", "低搁架", "高搁架", "低通", "高通", "带通", "陷波"][rawValue] }
    var hasGain: Bool { rawValue < 3 }
    var definition: String {
        switch self {
        case .bell: "RBJ 峰值 Q；中心频率处为设定增益，Q 不是倍频程带宽。"
        case .lowShelf, .highShelf: "RBJ 搁架 Q（不是斜率 S）；频率是半增益转折点，高 Q 允许过冲。"
        case .lowPass, .highPass: "二阶 12 dB/oct；频率是自然频率，仅 Q=0.7071 时该处约为 −3.01 dB。"
        case .bandPass: "二阶，中心增益为 0 dB；Q 控制带宽，没有单独的增益参数。"
        case .notch: "二阶陷波；频率为陷波零点，Q 控制宽度。"
        }
    }
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
    static func maximumFrequency(rate: Double) -> Double { min(20_000, rate * 0.498) }
    static func appliedFrequency(_ value: Double, rate: Double) -> Double { min(maximumFrequency(rate: rate), max(10, value)) }
    // Include band centres and closely spaced points around narrow, Nyquist-warped filters.
    func curveFrequencies(rate: Double) -> [Double] {
        let maximum = Self.maximumFrequency(rate: rate)
        var values: [Double] = []
        for index in 0...500 {
            let position = Double(index) / 500.0
            let frequency = 10.0 * pow(maximum / 10.0, position)
            values.append(min(maximum, frequency))
        }
        values.append(maximum)
        for band in bands where band.enabled {
            let centre = Self.appliedFrequency(band.frequency, rate: rate)
            let g = tan(.pi * centre / rate)
            for index in -96...96 {
                let warped = g * exp(Double(index) / (48.0 * max(0.1, band.q)))
                let frequency = rate / .pi * atan(warped)
                if frequency >= 10, frequency <= maximum { values.append(frequency) }
            }
            values.append(centre)
        }
        return Array(Set(values)).sorted()
    }

    func validate() throws {
        guard (1...32).contains(bands.count), preamp.isFinite, (-60...24).contains(preamp),
              Set(bands.map(\.id)).count == bands.count,
              bands.allSatisfy({ $0.frequency.isFinite && (10...20_000).contains($0.frequency) &&
                  $0.q.isFinite && (0.1...30).contains($0.q) && $0.gain.isFinite && (-24...24).contains($0.gain) }) else {
            throw PureToneError.message("EQ 参数超出范围，未应用此配置")
        }
    }

    func native(rate: Double, preamp override: Double? = nil) -> PTEQ {
        var result = pt_eq_default()
        result.enabled = enabled ? 1 : 0
        result.count = Int32(min(32, max(1, bands.count)))
        result.preampDB = override ?? preamp
        withUnsafeMutableBytes(of: &result.bands) { raw in
            let buffer = raw.bindMemory(to: PTBand.self)
            for (i, band) in bands.prefix(32).enumerated() {
                buffer[i] = PTBand(type: Int32(band.kind.rawValue), enabled: band.enabled ? 1 : 0,
                                   frequency: Self.appliedFrequency(band.frequency, rate: rate),
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
    var clientRate: Double = 0
    var remoteIORate: Double = 0
    var preferenceNote = ""
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
