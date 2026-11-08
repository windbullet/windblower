import SwiftUI

struct EqualizerView: View {
    @Environment(AudioController.self) private var audio
    @State private var selected: UUID?
    @State private var presetName = ""
    @State private var showSave = false
    private var rate: Double { audio.path.outputRate > 0 ? audio.path.outputRate : 48_000 }
    var body: some View {
        @Bindable var audio = audio
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) { Text("精确调整，保持透明").font(.title2.bold()); Text("64 位 TPT · 真实响应 · 静态防削波").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Toggle("启用 EQ", isOn: $audio.configuration.enabled).labelsHidden().disabled(audio.isStreaming || audio.streamingPending)
                }
                curve.frame(height: 240).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 18))
                if audio.transitioning { Label("正在切换，曲线显示目标响应", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary) }
                HStack { Text("10 Hz"); Spacer(); Text("100"); Spacer(); Text("1k"); Spacer(); Text("20k Hz") }.font(.caption2.monospaced()).foregroundStyle(.secondary)
                GroupBox {
                    VStack(spacing: 14) {
                        HStack { Text("前置增益").fontWeight(.medium); Spacer(); numeric($audio.configuration.preamp, unit: "dB", range: -60...24) }
                        Slider(value: $audio.configuration.preamp, in: -60...24, step: 0.1)
                        HStack { valueLabel("用户设定", audio.configuration.preamp); Spacer(); valueLabel("安全衰减", audio.path.safety); Spacer(); valueLabel("实际增益", audio.path.effectivePreamp) }
                        Text(audio.current == nil ? "选择歌曲后分析真峰值并校准安全增益。" : audio.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(6)
                }
                HStack { Text("滤波器 · \(audio.configuration.bands.count) 段").font(.headline); Spacer(); Button("添加", systemImage: "plus") { let band = EQBand(frequency: 1_000); audio.configuration.bands.append(band); selected = band.id }.disabled(audio.configuration.bands.count >= 32) }
                ForEach($audio.configuration.bands) { $band in
                    bandEditor($band)
                }
                Text("搁架的 Q 描述过渡形状；带通中心归一化。EQ 曲线包含当前实际前置增益，输出采样率变化时重新计算。").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .toolbar { ToolbarItem(placement: .primaryAction) { Menu {
            Button("保存预设") { showSave = true }
            ForEach(audio.presets) { preset in Button(preset.name) { audio.configuration = preset.configuration } }
            Button("重置参数", role: .destructive) { audio.configuration = EQConfiguration() }
        } label: { Label("预设", systemImage: "slider.horizontal.2.square") } } }
        .alert("保存 EQ 预设", isPresented: $showSave) { TextField("名称", text: $presetName); Button("保存") { if !presetName.isEmpty { audio.savePreset(name: presetName); presetName = "" } }; Button("取消", role: .cancel) {} }
    }
    private func valueLabel(_ name: String, _ value: Double) -> some View { VStack(alignment: .leading, spacing: 4) { Text(name).font(.caption2).foregroundStyle(.secondary); Text("\(value, specifier: "%.1f") dB").font(.subheadline.monospacedDigit()) } }
    private func numeric(_ value: Binding<Double>, unit: String, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 5) { TextField("", value: Binding(get: { value.wrappedValue }, set: { if $0.isFinite { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) } }), format: .number.precision(.fractionLength(0...3))).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder).frame(width: 90); Text(unit).font(.caption).foregroundStyle(.secondary) }
    }
    private func bandEditor(_ binding: Binding<EQBand>) -> some View {
        let band = binding.wrappedValue
        return VStack(spacing: 16) {
            HStack {
                Toggle("", isOn: binding.enabled).labelsHidden().scaleEffect(0.8)
                Picker("类型", selection: binding.kind) { ForEach(FilterKind.allCases) { kind in Text(kind.title).tag(kind) } }.pickerStyle(.menu)
                Spacer()
                Button { selected = band.id } label: { Image(systemName: selected == band.id ? "scope" : "circle.dashed") }
                Button(role: .destructive) { audio.configuration.bands.removeAll { $0.id == band.id } } label: { Image(systemName: "trash") }.disabled(audio.configuration.bands.count <= 1)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { numeric(binding.frequency, unit: "Hz", range: 10...min(20_000, rate * 0.498)); numeric(binding.q, unit: "Q", range: 0.1...30); if band.kind.hasGain { numeric(binding.gain, unit: "dB", range: -24...24) } }
                VStack { HStack { Text("频率"); Spacer(); numeric(binding.frequency, unit: "Hz", range: 10...min(20_000, rate * 0.498)) }; HStack { numeric(binding.q, unit: "Q", range: 0.1...30); Spacer(); if band.kind.hasGain { numeric(binding.gain, unit: "dB", range: -24...24) } } }
            }
            if band.kind.hasGain { Slider(value: binding.gain, in: -24...24, step: 0.1) }
        }.padding(16).background(.quaternary.opacity(selected == band.id ? 0.6 : 0.25), in: .rect(cornerRadius: 16)).opacity(band.enabled ? 1 : 0.55)
    }
    private var curve: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let range = 36.0
                func point(_ f: Double, _ gain: Double) -> CGPoint { CGPoint(x: log(f / 10) / log(2000) * size.width, y: (0.5 - gain / (range * 2)) * size.height) }
                for db in stride(from: -24.0, through: 24.0, by: 12) { var line = Path(); line.move(to: point(10, db)); line.addLine(to: point(20_000, db)); context.stroke(line, with: .color(.secondary.opacity(db == 0 ? 0.4 : 0.15)), lineWidth: 1) }
                for f in [100.0, 1_000.0, 10_000.0] { var line = Path(); line.move(to: point(f, -range)); line.addLine(to: point(f, range)); context.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 1) }
                var response = Path()
                for i in 0...500 {
                    let f = 10 * pow(2000, Double(i) / 500)
                    let config = audio.current == nil ? audio.configuration : (audio.appliedConfiguration ?? audio.configuration)
                    let gain = config.response(at: min(f, rate * 0.498), rate: rate, effectivePreamp: audio.current == nil ? nil : audio.path.effectivePreamp)
                    let p = point(f, max(-range, min(range, gain.isFinite ? gain : -range)))
                    if i == 0 { response.move(to: p) } else { response.addLine(to: p) }
                }
                context.stroke(response, with: .color(Color.accentGreen), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                for band in audio.configuration.bands where band.enabled {
                    let p = point(band.frequency, band.kind.hasGain ? band.gain : 0)
                    context.fill(Path(ellipseIn: CGRect(x: p.x-5, y: p.y-5, width: 10, height: 10)), with: .color(band.id == selected ? .orange : .accentGreen))
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let f = min(min(20_000, rate * 0.498), max(10, 10 * pow(2000, value.location.x / geometry.size.width)))
                if selected == nil { selected = audio.configuration.bands.min { abs(log($0.frequency / f)) < abs(log($1.frequency / f)) }?.id }
                if let i = audio.configuration.bands.firstIndex(where: { $0.id == selected }) { audio.configuration.bands[i].frequency = f; if audio.configuration.bands[i].kind.hasGain { audio.configuration.bands[i].gain = min(24, max(-24, (0.5 - value.location.y / geometry.size.height) * 72)) } }
            })
        }.clipped()
    }
}
