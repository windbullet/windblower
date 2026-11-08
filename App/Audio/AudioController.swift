import Foundation
import AVFAudio
import AudioToolbox
import MediaPlayer
import Observation
import CryptoKit
import UIKit
import Darwin

private func checkAudio(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw PureToneError.message("\(action)：Core Audio \(status)") }
}

// The callback only reads the native SPSC ring into RemoteIO's supplied buffer.
private let audioRender: AURenderCallback = { reference, _, _, _, frames, data in
    guard let reference, let data else { return kAudio_ParamError }
    let buffers = UnsafeMutableAudioBufferListPointer(data)
    guard buffers.count == 1, let bytes = buffers[0].mData,
          buffers[0].mDataByteSize >= frames * 2 * UInt32(MemoryLayout<Float>.size) else { return kAudio_ParamError }
    let player = OpaquePointer(reference)
    _ = pt_player_render(player, bytes.assumingMemoryBound(to: Float.self), Int(frames))
    return noErr
}

actor Analyzer {
    private let db: Database
    init(db: Database) { self.db = db }
    func analyze(url: URL, hash: String, rate: Double, configuration: EQConfiguration) throws -> PeakReport {
        try analyzeSequence(urls: [url], hashes: [hash], rate: rate, configuration: configuration)
    }
    func analyzeSequence(urls: [URL], hashes: [String], rate: Double, configuration: EQConfiguration) throws -> PeakReport {
        try Task.checkCancellation()
        guard !urls.isEmpty, urls.count == hashes.count else { throw PureToneError.message("无效的连续音轨分析请求") }
        let encoded = try JSONEncoder().encode(configuration)
        var keyData = encoded
        keyData.append(try JSONEncoder().encode(hashes))
        keyData.append(Data("|\(rate)|\(PT_CORE_VERSION)".utf8))
        let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
        struct Cached: Codable { var key: String; var report: PeakReport }
        if let cached = try db.all(Cached.self, kind: "analysis").first(where: { $0.key == key }) { return cached.report }
        var eq = configuration.native(rate: rate); var result = PTAnalysis()
        let storage = urls.map { strdup($0.path) }
        defer { for value in storage { free(value) } }
        guard storage.allSatisfy({ $0 != nil }) else { throw PureToneError.message("无法分配分析路径") }
        let paths = storage.map { $0.map { UnsafePointer<CChar>($0) } }
        let success = paths.withUnsafeBufferPointer {
            pt_analyze_sequence_cancelable($0.baseAddress, $0.count, rate, &eq, &result, nil, { _ in Task<Never, Never>.isCancelled ? 1 : 0 })
        }
        try Task.checkCancellation()
        guard success == 1 else { throw PureToneError.core }
        let report = PeakReport(result)
        try db.put(Cached(key: key, report: report), kind: "analysis", id: key)
        return report
    }
}

@MainActor @Observable final class AudioController {
    var configuration: EQConfiguration { didSet { persistEQ(); scheduleEQ() } }
    var presets: [EQPreset] = []
    var queue: [Track] = []
    var index = 0
    private var streamTrack: Track?
    var current: Track? { streamTrack ?? (queue.indices.contains(index) ? queue[index] : nil) }
    var playing = false
    var preparing = false
    var progress: Double = 0
    var path = SignalPath()
    var analysis: PeakReport?
    var status = "选择一首音乐"
    var appliedConfiguration: EQConfiguration?
    var transitioning = false
    var isStreaming: Bool { streamTrack != nil }
    var streamingPending = false
    var error: String?
    var shuffle = false
    var repeatMode: RepeatMode = .off { didSet { if let player { pt_player_clear_next(player); prepareNext() } } }
    var sleepDeadline: Date?
    private let library: LibraryStore
    private let analyzer: Analyzer
    private var unit: AudioUnit?
    private var player: OpaquePointer?
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var eqTask: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var queuedNative = false
    private var observedNativeTrack: UInt64 = 0
    private var albumGain: Double?
    private var wasInterrupted = false
    private var generation = UUID()
    private var streamSource: RangeByteSource?
    private var targetEQRevision: UInt64 = 0
    private var unshuffledQueue: [Track] = []

    private func analysisGroup(for track: Track, configuration: EQConfiguration) -> [Track] {
        guard configuration.enabled, queue.indices.contains(index) else { return [track] }
        let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
        return Array(queue[index...].prefix {
            $0.album == track.album && ($0.albumArtist.isEmpty ? $0.artist : $0.albumArtist) == artist &&
            $0.sampleRate == track.sampleRate && $0.channels == track.channels
        })
    }

    init(library: LibraryStore) {
        self.library = library; analyzer = Analyzer(db: library.db)
        let saved = (try? library.db.all(EQConfiguration.self, kind: "eq").first) ?? EQConfiguration()
        configuration = (try? saved.validate()) != nil ? saved : EQConfiguration()
        presets = ((try? library.db.all(EQPreset.self, kind: "preset")) ?? []).filter { (try? $0.configuration.validate()) != nil }
        installRemoteCommands()
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let value = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if value == AVAudioSession.InterruptionType.began.rawValue { self.wasInterrupted = self.playing; self.pause() }
                else if self.wasInterrupted && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self.resume() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self else { return }
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self.pause() }
                else if self.current != nil && !self.preparing { self.restartForRoute() }
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        restoreQueue()
    }

    func play(_ tracks: [Track], startingAt selected: Track) {
        guard !tracks.isEmpty else { return }
        streamTrack = nil
        queue = tracks; index = tracks.firstIndex(of: selected) ?? 0
        unshuffledQueue = tracks
        if shuffle { queue.shuffle(); index = queue.firstIndex(of: selected) ?? 0 }
        startCurrent()
    }
    func playStream(_ source: RangeByteSource, title: String, provenance: String) async {
        request?.cancel(); eqTask?.cancel(); nextTask?.cancel(); releaseOutput()
        streamTrack = nil
        generation = UUID(); let ticket = generation
        preparing = true; playing = false; streamSource = source; streamingPending = true; status = "缓冲原始音频…"
        defer { if generation == ticket { streamingPending = false } }
        do {
            let info = try await Task.detached { try source.probe() }.value
            guard ticket == generation else { return }
            let rate = try configureSession(sourceRate: info.sampleRate)
            var config = configuration; config.enabled = false
            let settings = config
            let bits = try await Task.detached { try source.createPlayer(rate: rate, configuration: settings) }.value
            guard ticket == generation, let created = OpaquePointer(bitPattern: bits) else {
                if let stale = OpaquePointer(bitPattern: bits) { pt_player_destroy(stale) }; return
            }
            streamTrack = Track(id: "stream-\(UUID().uuidString)", relativePath: "stream.\(source.fileExtension)", title: title, artist: "网络原文件串流", album: provenance, duration: info.duration, sampleRate: info.sampleRate, bitDepth: info.bitDepth, channels: info.channels)
            player = created; try installOutput(player: created, rate: rate)
            progress = 0; analysis = nil; appliedConfiguration = config; path.effectivePreamp = 0; path.safety = 0
            preparing = false; status = "原文件范围读取 · EQ 旁路 · \(provenance)"; resume()
        } catch {
            guard ticket == generation else { return }
            preparing = false; self.error = error.localizedDescription; releaseOutput()
        }
    }
    func toggle() { playing ? pause() : resume() }
    func pause() {
        if let player { pt_player_pause(player, 1) }
        playing = false; updateNowPlaying(); persistQueue()
    }
    func resume() {
        guard !preparing else { return }
        guard let player else { if current != nil { startCurrent(at: progress) }; return }
        do { try AVAudioSession.sharedInstance().setActive(true); if let unit { try checkAudio(AudioOutputUnitStart(unit), "启动输出") }; pt_player_pause(player, 0); playing = true; updateNowPlaying() }
        catch { self.error = error.localizedDescription }
    }
    func next() {
        if isStreaming { pause(); return }
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count { index += 1 }
        else if repeatMode == .all { index = 0 } else { pause(); return }
        startCurrent()
    }
    func previous() {
        if isStreaming { seek(0); return }
        if progress > 3 { seek(0); return }
        index = max(0, index - 1); startCurrent()
    }
    func playNext(_ track: Track) {
        if queue.isEmpty { play([track], startingAt: track) }
        else { queue.insert(track, at: min(index + 1, queue.count)); queuedNative = false; if let player { pt_player_clear_next(player) }; prepareNext() }
    }
    func toggleShuffle() {
        guard let track = current, !isStreaming else { shuffle.toggle(); return }
        shuffle.toggle()
        let position = progress, wasPlaying = playing
        if shuffle { unshuffledQueue = queue; let remaining = queue.filter { $0.id != track.id }.shuffled(); queue = [track] + remaining; index = 0 }
        else { queue = unshuffledQueue; index = queue.firstIndex(of: track) ?? 0 }
        startCurrent(at: position, autoplay: wasPlaying)
    }
    func seek(_ seconds: Double) {
        guard let player else { return }
        let seconds = max(0, min(seconds, max(0, (current?.duration ?? 0) - 0.01)))
        if let unit { AudioOutputUnitStop(unit) }
        if pt_player_seek(player, seconds) == 0 { error = PureToneError.core.localizedDescription }
        if let unit { AudioOutputUnitStart(unit) }
        queuedNative = false; prepareNext(); progress = seconds; updateNowPlaying()
    }

    private func configureSession(sourceRate: Double) throws -> Double {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false)
        do { try session.setCategory(.playback, mode: .measurement, options: []) }
        catch { try session.setCategory(.playback, mode: .default, options: []) }
        try session.setPreferredSampleRate(sourceRate)
        try session.setPreferredIOBufferDuration(0.023)
        try session.setActive(true)
        path.sourceRate = sourceRate; path.outputRate = session.sampleRate
        path.sessionMode = session.mode == .measurement ? "Measurement" : "Default（系统回退）"
        path.route = session.currentRoute.outputs.map(\.portName).joined(separator: " / ")
        path.outputLatency = session.outputLatency; path.bufferDuration = session.ioBufferDuration
        return session.sampleRate
    }

    private func installOutput(player: OpaquePointer, rate: Double) throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_RemoteIO,
                                                     componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw PureToneError.message("RemoteIO 不可用") }
        var created: AudioUnit?
        try checkAudio(AudioComponentInstanceNew(component, &created), "创建 RemoteIO")
        guard let created else { throw PureToneError.message("无法创建 RemoteIO") }
        unit = created
        var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8,
                                                 mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        try checkAudio(AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout.size(ofValue: format))), "设置输出格式")
        var callback = AURenderCallbackStruct(inputProc: audioRender, inputProcRefCon: UnsafeMutableRawPointer(player))
        try checkAudio(AudioUnitSetProperty(created, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout.size(ofValue: callback))), "设置回调")
        try checkAudio(AudioUnitInitialize(created), "初始化音频输出")
    }

    private func releaseOutput() {
        if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        unit = nil
        streamSource?.cancel()
        if let player { pt_player_destroy(player) }; player = nil; streamSource = nil
        queuedNative = false; observedNativeTrack = 0
    }

    private func startCurrent(at seconds: Double = 0, autoplay: Bool = true) {
        request?.cancel(); eqTask?.cancel(); nextTask?.cancel(); releaseOutput()
        generation = UUID(); let ticket = generation
        guard let track = current else { return }
        playing = false; preparing = true; progress = seconds; analysis = nil; albumGain = nil; transitioning = false
        status = configuration.enabled ? "分析完整链路与真峰值…" : "准备原采样率播放…"
        request = Task {
            do {
                let rate = try configureSession(sourceRate: track.sampleRate)
                let config = configuration
                let group = analysisGroup(for: track, configuration: config)
                let report = try await analyzer.analyzeSequence(urls: group.map { library.url($0) }, hashes: group.map(\.id), rate: rate, configuration: config)
                guard !Task.isCancelled, generation == ticket else { return }
                analysis = report
                let gain = report.effectivePreamp
                if config.enabled { albumGain = gain }
                guard config == configuration else { startCurrent(at: seconds, autoplay: autoplay); return }
                var native = config.native(rate: rate)
                guard let created = pt_player_create(library.url(track).path, rate, &native, gain) else { throw PureToneError.core }
                player = created; try installOutput(player: created, rate: rate)
                if seconds > 0 { guard pt_player_seek(created, seconds) == 1 else { throw PureToneError.core } }
                path.effectivePreamp = gain; path.safety = config.enabled ? gain - config.preamp : 0; appliedConfiguration = config
                preparing = false; status = config.enabled ? "EQ 已校准 · 静态安全增益" : (path.resampling ? "一次 VHQ 采样率转换" : "App 内 PCM 直通")
                if autoplay { resume() }; persistQueue(); prepareNext()
            } catch {
                guard generation == ticket else { return }
                preparing = false; self.error = error.localizedDescription; status = "无法播放"; releaseOutput()
            }
        }
    }

    private func prepareNext() {
        nextTask?.cancel()
        guard let player, index + 1 < queue.count, let track = current, repeatMode != .one, !isStreaming else { return }
        let next = queue[index + 1]
        guard next.sampleRate == track.sampleRate && next.channels == track.channels else { return }
        if configuration.enabled && analysisGroup(for: track, configuration: configuration).count < 2 { return }
        let ticket = generation; let config = configuration; let rate = path.outputRate
        nextTask = Task {
            do {
                if !config.enabled { _ = try await analyzer.analyze(url: library.url(next), hash: next.id, rate: rate, configuration: config) }
                guard !Task.isCancelled, ticket == generation else { return }
                let nextPath = library.url(next).path
                let bits = try await Task.detached {
                    guard let prepared = pt_prepare_track(nextPath, rate) else { throw PureToneError.core }
                    return UInt(bitPattern: prepared)
                }.value
                guard let prepared = OpaquePointer(bitPattern: bits) else { return }
                guard !Task.isCancelled, ticket == generation else { pt_prepared_track_destroy(prepared); return }
                queuedNative = pt_player_enqueue_prepared(player, prepared) == 1
                if !queuedNative { pt_prepared_track_destroy(prepared) }
            } catch { /* The next track is retried through the normal error-reporting path. */ }
        }
    }

    private func scheduleEQ() {
        eqTask?.cancel(); nextTask?.cancel()
        if let player { pt_player_clear_next(player) }
        if isStreaming {
            if configuration.enabled { error = "网络即时串流需保持 EQ 旁路；请先使用“缓存后播放”以完整分析峰值。" }
            return
        }
        guard let player, let track = current, let report = analysis, !preparing else { return }
        let rate = path.outputRate; let config = configuration; let ticket = generation
        eqTask = Task {
            do {
                var native = config.native(rate: rate)
                let bound = pt_eq_l1_bound(&native, rate)
                guard bound.isFinite, bound > 0 else { throw PureToneError.message("该 EQ 超出安全数值范围") }
                let conservative = config.enabled && report.inputPeak > 0
                    ? config.preamp + min(0, -13 - 20 * log10(report.inputPeak * bound)) : 0
                targetEQRevision = pt_player_set_eq_revision(player, &native, conservative)
                guard targetEQRevision > 0 else { throw PureToneError.core }
                transitioning = true
                appliedConfiguration = config
                path.effectivePreamp = conservative; path.safety = conservative - (config.enabled ? config.preamp : 0)
                status = "EQ 实时试听 · 保守余量 · 过渡中"
                try await Task.sleep(for: .milliseconds(450))
                let group = analysisGroup(for: track, configuration: config)
                let r = try await analyzer.analyzeSequence(urls: group.map { library.url($0) }, hashes: group.map(\.id), rate: rate, configuration: config)
                guard !Task.isCancelled, ticket == generation else { return }
                let finalGain = r.effectivePreamp
                var applied = config.native(rate: rate)
                targetEQRevision = pt_player_set_eq_revision(player, &applied, finalGain)
                guard targetEQRevision > 0 else { throw PureToneError.core }
                analysis = r; albumGain = config.enabled ? finalGain : nil
                path.effectivePreamp = finalGain; path.safety = config.enabled ? finalGain - config.preamp : 0
                transitioning = true
                status = config.enabled ? "EQ 校准完成 · 正在切换" : "EQ 正在旁路"
                prepareNext()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    func savePreset(name: String) {
        let preset = EQPreset(name: name, configuration: configuration)
        do { try library.db.put(preset, kind: "preset", id: preset.id.uuidString); presets.append(preset) }
        catch { self.error = error.localizedDescription }
    }
    private func persistEQ() { try? library.db.put(configuration, kind: "eq", id: "current") }
    private func restartForRoute() {
        if isStreaming { pause(); status = "输出路由已改变，请重新选择网络歌曲"; return }
        let pos = progress; let wasPlaying = playing; startCurrent(at: pos, autoplay: wasPlaying)
    }
    private func tick() {
        if let deadline = sleepDeadline, Date() >= deadline { pause(); sleepDeadline = nil }
        guard let player, !preparing else { return }
        progress = pt_player_position(player); path.underruns = pt_player_underruns(player)
        if transitioning && targetEQRevision > 0 && pt_player_eq_revision(player) >= targetEQRevision {
            // The ring carries audible revisions; no claim that queued DSP is already audible.
            transitioning = false
            status = (appliedConfiguration?.enabled ?? false) ? "EQ 已生效 · 静态安全增益" : "EQ 已旁路"
        }
        let nativeTrack = pt_player_track_index(player)
        if nativeTrack > observedNativeTrack {
            index += Int(nativeTrack - observedNativeTrack); observedNativeTrack = nativeTrack; queuedNative = false
            updateNowPlaying(); persistQueue(); prepareNext()
        }
        if playing && pt_player_state(player) == 2 {
            if repeatMode == .one { seek(0) } else { next() }
        } else if pt_player_state(player) == -1 && playing { pause(); status = "解码／网络读取异常或数字过载，已暂停"; error = status }
    }
    private func updateNowPlaying() {
        guard let track = current else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist,
                                  MPMediaItemPropertyAlbumTitle: track.album, MPMediaItemPropertyPlaybackDuration: track.duration,
                                  MPNowPlayingInfoPropertyElapsedPlaybackTime: progress, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
        if let art = track.artworkPath, let image = UIImage(contentsOfFile: Paths.artwork.appendingPathComponent(art).path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func installRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime; Task { @MainActor in self?.seek(seconds) }; return .success
        }
    }
    private struct SavedQueue: Codable { var ids: [String]; var index: Int; var position: Double }
    private func persistQueue() { try? library.db.put(SavedQueue(ids: queue.map(\.id), index: index, position: progress), kind: "queue", id: "current") }
    private func restoreQueue() {
        if let saved = try? library.db.all(SavedQueue.self, kind: "queue").first {
            queue = saved.ids.compactMap { id in library.tracks.first { $0.id == id } }; index = min(saved.index, max(0, queue.count - 1)); progress = saved.position
        }
    }
}
