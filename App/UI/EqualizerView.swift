import SwiftUI

struct EqualizerView: View {
    @Environment(AudioController.self) private var audio
    @State private var presetName = ""
    @State private var showSave = false
    private var rate: Double { audio.path.outputRate > 0 ? audio.path.outputRate : 48_000 }
    private var maximumFrequency: Double { EQConfiguration.maximumFrequency(rate: rate) }
    var body: some View {
        @Bindable var audio = audio
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                curve.frame(height: 240).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 18))
                if audio.transitioning { Label("正在准备或切换；曲线显示已提交的配置，过渡期间响应会变化", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary) }
                Text("数字 RBJ / TPT 响应 · 常规 IIR 相位 · EQ 不过采样 · 无动态 EQ 或模拟染色").font(.caption).foregroundStyle(.secondary)
                preampPanel
                HStack { Text("滤波器 · \(audio.configuration.bands.count) 段").font(.headline); Spacer(); Button("添加", systemImage: "plus") { audio.configuration.bands.append(EQBand(frequency: 1_000)) }.disabled(audio.configuration.bands.count >= 32) }
                ForEach(audio.configuration.bands) { band in
                    bandEditor(Self.bandBinding(for: band, in: audio))
                }
                Text("曲线只显示总响应（含实际前置增益），通过下方滑块或数值输入调整。横轴为对数频率，纵轴为等距 dB。搁架采用 Q 而非斜率 S；带通中心归一化。").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .toolbar { ToolbarItem(placement: .primaryAction) { Menu {
            Button("保存预设") { showSave = true }
            ForEach(audio.presets) { preset in Button(preset.name) { audio.configuration = preset.configuration } }
            Button("重置参数", role: .destructive) { audio.configuration = EQConfiguration() }
        } label: { Label("预设", systemImage: "slider.horizontal.2.square") } } }
        .alert("保存 EQ 预设", isPresented: $showSave) { TextField("名称", text: $presetName); Button("保存") { if !presetName.isEmpty { audio.savePreset(name: presetName); presetName = "" } }; Button("取消", role: .cancel) {} }
    }
    private var header: some View {
        @Bindable var audio = audio
        return HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("精确调整，保持透明").font(.title2.bold())
                Text("64 位 TPT · 真实响应 · 静态防削波").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("启用 EQ", isOn: $audio.configuration.enabled).labelsHidden().disabled(audio.isStreaming || audio.streamingPending)
        }
    }
    private var preampPanel: some View {
        @Bindable var audio = audio
        return GroupBox {
            VStack(spacing: 14) {
                HStack { Text("前置增益").fontWeight(.medium); Spacer(); numeric($audio.configuration.preamp, unit: "dB", range: -60...24) }
                Slider(value: $audio.configuration.preamp, in: -60...24, step: 0.1)
                Toggle("A/B 保持共同前置增益", isOn: $audio.preserveABGain).font(.subheadline)
                Text("开关不重新校准 EQ。关闭此选项时旁路不保留 EQ 前置；若解码/SRC 后会超满刻度，仍保留单独测得的固定安全衰减。频谱变化仍可能改变听感响度。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    valueLabel("用户设定", audio.configuration.preamp)
                    Spacer()
                    valueLabel("安全衰减", audio.path.safety)
                    Spacer()
                    valueLabel(audio.transitioning ? "目标增益" : "实际增益", audio.path.effectivePreamp)
                }
                Text(audio.current == nil ? "选择歌曲后分析真峰值并校准安全增益。" : audio.status)
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(6)
        }
    }
    private func valueLabel(_ name: String, _ value: Double) -> some View { VStack(alignment: .leading, spacing: 4) { Text(name).font(.caption2).foregroundStyle(.secondary); Text("\(value, specifier: "%.1f") dB").font(.subheadline.monospacedDigit()) } }
    private func numeric(_ value: Binding<Double>, unit: String, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 5) { TextField("", value: Binding(get: { value.wrappedValue }, set: { if $0.isFinite { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) } }), format: .number.precision(.fractionLength(0...3))).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder).frame(width: 90); Text(unit).font(.caption).foregroundStyle(.secondary) }
    }
    private func bandEditor(_ binding: Binding<EQBand>) -> some View {
        let band = binding.wrappedValue
        let actualFrequency = EQConfiguration.appliedFrequency(band.frequency, rate: rate)
        return VStack(spacing: 16) {
            HStack {
                Toggle("", isOn: binding.enabled).labelsHidden().scaleEffect(0.8)
                Picker("类型", selection: binding.kind) { ForEach(FilterKind.allCases) { kind in Text(kind.title).tag(kind) } }.pickerStyle(.menu)
                Spacer()
                Button(role: .destructive) {
                    audio.removeBand(id: band.id)
                } label: { Image(systemName: "trash") }.disabled(audio.configuration.bands.count <= 1)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { numeric(binding.frequency, unit: "Hz", range: 10...min(20_000, rate * 0.498)); numeric(binding.q, unit: "Q", range: 0.1...30); if band.kind.hasGain { numeric(binding.gain, unit: "dB", range: -24...24) } }
                VStack { HStack { Text("频率"); Spacer(); numeric(binding.frequency, unit: "Hz", range: 10...min(20_000, rate * 0.498)) }; HStack { numeric(binding.q, unit: "Q", range: 0.1...30); Spacer(); if band.kind.hasGain { numeric(binding.gain, unit: "dB", range: -24...24) } } }
            }
            HStack { Text("频率").font(.caption); Slider(value: Binding(get: { log10(actualFrequency) }, set: { binding.wrappedValue.frequency = pow(10, $0) }), in: 1...log10(maximumFrequency)) }
            HStack { Text("Q 值").font(.caption); Slider(value: Binding(get: { log10(band.q) }, set: { binding.wrappedValue.q = pow(10, $0) }), in: log10(0.1)...log10(30.0)) }
            if band.kind.hasGain { Slider(value: binding.gain, in: -24...24, step: 0.1) }
            Text(band.kind.definition).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if actualFrequency != band.frequency { Text("受当前采样率限制：保存值 \(band.frequency, specifier: "%.1f") Hz，实际生效 \(actualFrequency, specifier: "%.1f") Hz").font(.caption).foregroundStyle(.orange) }
        }.padding(16).background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 16)).opacity(band.enabled ? 1 : 0.55)
    }
    private var curve: some View {
        let config = audio.current == nil ? audio.configuration : (audio.appliedConfiguration ?? audio.configuration)
        let preamp = audio.current == nil ? nil : audio.path.effectivePreamp
        return EQCurvePlot(configuration: config, rate: rate, preamp: preamp)
    }
    // SwiftUI can still read/write an outgoing row during removal. Never retain an array index.
    static func bandBinding(for snapshot: EQBand, in audio: AudioController) -> Binding<EQBand> {
        Binding(get: {
            audio.configuration.bands.first { $0.id == snapshot.id } ?? snapshot
        }, set: { updated in
            guard let index = audio.configuration.bands.firstIndex(where: { $0.id == snapshot.id }) else { return }
            audio.configuration.bands[index] = updated
        })
    }
}

private struct EQCurvePlot: View {
    let configuration: EQConfiguration
    let rate: Double
    let preamp: Double?

    var body: some View {
        Canvas { context, size in
            EQCurveDrawing.draw(context: &context, size: size, configuration: configuration,
                                rate: rate, preamp: preamp)
        }.clipped()
            .allowsHitTesting(false)
            .accessibilityLabel("EQ 总响应，横轴为对数频率，纵轴为分贝；在下方调整参数")
    }
}

struct EQPlotScale {
    let maximumFrequency: Double
    func frequencyPosition(_ frequency: Double) -> Double { log10(frequency / 10) / log10(maximumFrequency / 10) }
    func gainPosition(_ gain: Double) -> Double { (36 - gain) / 72 }
    var frequencyTicks: [Double] {
        ([10.0, 20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000].filter { $0 < maximumFrequency } + [maximumFrequency])
    }
}

private enum EQCurveDrawing {
    static func draw(context: inout GraphicsContext, size: CGSize, configuration: EQConfiguration,
                     rate: Double, preamp: Double?) {
        let range = 36.0
        let maximum = EQConfiguration.maximumFrequency(rate: rate)
        let scale = EQPlotScale(maximumFrequency: maximum)
        let plot = CGRect(x: 40, y: 14, width: max(1, size.width - 56), height: max(1, size.height - 42))
        func point(_ frequency: Double, _ gain: Double) -> CGPoint {
            CGPoint(x: plot.minX + scale.frequencyPosition(frequency) * plot.width,
                    y: plot.minY + scale.gainPosition(gain) * plot.height)
        }
        for db in stride(from: -36.0, through: 36.0, by: 12.0) {
            var line = Path(); line.move(to: point(10, db)); line.addLine(to: point(maximum, db))
            context.stroke(line, with: .color(Color.secondary.opacity(db == 0 ? 0.4 : 0.15)), lineWidth: 1)
            let label = Text(String(format: "%+.0f", db)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: plot.minX - 6, y: point(10, db).y), anchor: .trailing)
        }
        var lastLabelX = -Double.infinity
        for frequency in scale.frequencyTicks {
            var line = Path(); line.move(to: point(frequency, -range)); line.addLine(to: point(frequency, range))
            context.stroke(line, with: .color(Color.secondary.opacity(0.15)), lineWidth: 1)
            let x = point(frequency, 0).x
            let isLast = frequency == maximum
            guard isLast || (x - lastLabelX >= 40 && plot.maxX - x >= 42) else { continue }
            let title = frequency >= 1_000 ? String(format: "%.3gk", frequency / 1_000) : String(format: "%.0f", frequency)
            context.draw(Text(title).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary),
                         at: CGPoint(x: x, y: plot.maxY + 14), anchor: isLast ? .trailing : (frequency == 10 ? .leading : .center))
            lastLabelX = x
        }
        var response = Path()
        for (index, frequency) in configuration.curveFrequencies(rate: rate).enumerated() {
            let gain = configuration.response(at: frequency, rate: rate, effectivePreamp: preamp)
            let p = point(frequency, max(-range, min(range, gain.isFinite ? gain : -range)))
            if index == 0 { response.move(to: p) } else { response.addLine(to: p) }
        }
        context.stroke(response, with: .color(Color.accentGreen), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
    }
}
