import Foundation
import SwiftUI
import UniformTypeIdentifiers

private func nmrText(_ v: Double) -> String { v.isFinite ? String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), v) : "超范围" }
private func nmrParse(_ text: String) throws -> Double {
    guard let v = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), v.isFinite else { throw NMRAnalysisError.message("请输入有限数值") }; return v
}
private struct NMRCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(_ text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents, let t = String(data: d, encoding: .utf8) else { throw NMRAnalysisError.message("CSV 编码无效") }; text = t
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
private enum NMRPage: String, CaseIterable { case region = "选区域", gain = "归一化", integral = "积分", fit = "去卷积", marks = "标峰", lines = "J 值 / 峰形" }
private struct NMRLayer { let points: [NMRXY]; let color: Color }

// Original descending-ppm plot; residual strip has its own symmetric vertical scale.
private struct NMRStrip: View {
    let title: String; let window: NMRBand; let layers: [NMRLayer]; let marks: [Double]; let seeds: [Double]
    let gain: Double; let residual: Bool; let gesture: (Double,Double) -> Void
    private var bounds: (Double,Double) {
        var a = Double.infinity, b = -Double.infinity
        for l in layers { for p in l.points where p.y.isFinite { a = min(a,p.y); b = max(b,p.y) } }
        guard a.isFinite, b.isFinite else { return (-1,1) }
        if residual { let m = max(abs(a),abs(b)); return m > 0 ? (-m,m) : (-1,1) }
        return (a,b)
    }
    var body: some View {
        let (lo,hi) = bounds
        return VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text("显示强度  \(nmrText(lo*gain)) … \(nmrText(hi*gain))") }.font(.caption)
            GeometryReader { geo in
                Canvas { ctx, size in
                    func px(_ x: Double) -> CGFloat { CGFloat((window.hi-x)/window.width)*size.width }
                    func py(_ y: Double) -> CGFloat { let f = hi > lo && (hi-lo).isFinite ? (hi-y)/(hi-lo) : 0.5; return 2+CGFloat(f)*max(0,size.height-4) }
                    func vertical(_ x: Double, _ color: Color) { var p = Path(); p.move(to: CGPoint(x: px(x), y: 0)); p.addLine(to: CGPoint(x: px(x), y: size.height)); ctx.stroke(p, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3,3])) }
                    if residual { var zero = Path(); zero.move(to: CGPoint(x: 0,y: py(0))); zero.addLine(to: CGPoint(x: size.width,y: py(0))); ctx.stroke(zero, with: .color(.gray.opacity(0.5)), lineWidth: 1) }
                    for l in layers {
                        var p = Path(), first = true
                        for s in l.points where s.x.isFinite && s.y.isFinite { let q = CGPoint(x: px(s.x), y: py(s.y)); if first { p.move(to: q); first = false } else { p.addLine(to: q) } }; ctx.stroke(p, with: .color(l.color), lineWidth: 1.2)
                    }
                    for x in seeds { vertical(x,.orange) }; for x in marks { vertical(x,.purple) }
                }
                .background(Color.secondary.opacity(0.07)).clipped().contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                    func ppm(_ x: CGFloat) -> Double { let f = Double(min(1,max(0,x/max(geo.size.width,1)))); return min(window.hi,max(window.lo,window.hi-window.width*f)) }; gesture(ppm(v.startLocation.x),ppm(v.location.x))
                })
            }.frame(height: residual ? 54 : 152)
            if !residual { HStack { Text(nmrText(window.hi)); Spacer(); Text("ppm"); Spacer(); Text(nmrText(window.lo)) }.font(.caption.monospacedDigit()) }
        }
    }
}

struct NMRRegionAnalysisView: View {
    let trace: NMRTrace
    @Binding var record: NMRAnalysisRecord
    let ports: NMRAnalysisPorts
    init(trace: NMRTrace, record: Binding<NMRAnalysisRecord>, ports: NMRAnalysisPorts, tool: NMRPostTool) {
        self.trace = trace; _record = record; self.ports = ports
        let initial: NMRPage
        switch tool {
        case .region: initial = .region
        case .normalize: initial = .gain
        case .integrate: initial = .integral
        case .deconvolve: initial = .fit
        case .markPeaks: initial = .marks
        case .coupling: initial = .lines
        }
        _page = State(initialValue: initial)
    }
    @Environment(\.dismiss) private var dismiss
    @State private var page: NMRPage = .region
    @State private var loText = ""
    @State private var hiText = ""
    @State private var gainTarget = "1"
    @State private var refTarget = "1"
    @State private var position = ""
    @State private var frequency = ""
    @State private var firstOrder = false
    @State private var notice = ""
    @State private var preview: [NMRXY] = []
    @State private var job: UUID?; @State private var discard = false
    @State private var saving = false; @State private var document = NMRCSVDocument()
    private func checkedBand() throws -> NMRBand { try NMRAnalysis.band(trace,record,ports) }
    private var window: NMRBand? { try? checkedBand() }
    private var gain: Double { record.displayGain ?? 1 }
    private func active(_ original: [Double], _ w: NMRBand) -> [Double] { original.map(ports.fromOriginalPPM).filter(w.contains).sorted() }
    private func run(_ action: () throws -> Void) { do { notice = ""; try action() } catch { notice = error.localizedDescription } }
    private func invalidateJob() { if job != nil { discard = true } }
    private func reload() {
        invalidateJob(); preview = []
        run { let w = try checkedBand(); loText = String(w.lo); hiText = String(w.hi); preview = trace.preview(try trace.indices(in: w)) }
    }
    private func applyBand() {
        run { let w = try NMRBand(nmrParse(loText),nmrParse(hiText)); _ = try trace.indices(in: w); let original = w.mapped(ports.toOriginalPPM)
            guard original.valid else { throw NMRAnalysisError.message("原轴区域无效") }; _ = try trace.indices(in: original.mapped(ports.fromOriginalPPM)); record.cropOriginalPPM = original; notice = "区域已保存"
        }
    }
    private func addPosition(_ x: Double, seed: Bool) throws {
        let w = try checkedBand(), u = ports.toOriginalPPM(x)
        guard w.contains(x), u.isFinite else { throw NMRAnalysisError.message("位置须在工作区内") }
        let list = seed ? record.seedsOriginalPPM : record.marksOriginalPPM
        guard !list.contains(u), list.count < 128 else { throw NMRAnalysisError.message("位置重复或标记过多") }
        if seed { record.seedsOriginalPPM.append(u) } else { record.marksOriginalPPM.append(u) }
    }
    private func plotGesture(_ a: Double, _ b: Double) {
        switch page {
        case .region: if a != b { let w = NMRBand(a,b); loText = String(w.lo); hiText = String(w.hi); notice = "核对边界后应用" }
        case .fit, .marks: run { try addPosition(b, seed: page == .fit) }
        default: break
        }
    }
    private func currentFit(_ w: NMRBand) -> NMRFit? {
        guard let f = record.fit, f.traceKey == trace.key, f.windowPPM == w, f.seedPPM == active(record.seedsOriginalPPM,w), f.shape == record.shape, f.lorentzFraction == record.shape.fraction(record.mix) else { return nil }; return f
    }
    private func layers(_ fit: NMRFit?) -> [NMRLayer] {
        var out = [NMRLayer(points: preview, color: .primary)]
        if let f = fit, !f.curve.isEmpty {
            out.append(NMRLayer(points: f.curve.map { NMRXY(x: $0.ppm,y: $0.backgroundRaw) }, color: .gray))
            for c in f.components { out.append(NMRLayer(points: f.curve.map { NMRXY(x: $0.ppm,y: $0.backgroundRaw+c.value(atPPM: $0.ppm)) }, color: .green.opacity(0.8))) }
            out.append(NMRLayer(points: f.curve.map { NMRXY(x: $0.ppm,y: $0.fittedRaw) }, color: .blue))
        }; return out
    }
    @ViewBuilder private var plots: some View {
        if let w = window {
            let f = currentFit(w)
            NMRStrip(title: "谱线 · 蓝 总拟合 · 绿 组分加背景 · 灰 背景", window: w, layers: layers(f), marks: active(record.marksOriginalPPM,w), seeds: active(record.seedsOriginalPPM,w), gain: gain, residual: false, gesture: plotGesture)
            if let fit = f, !fit.curve.isEmpty { NMRStrip(title: "残差：实测 − 总拟合", window: w, layers: [NMRLayer(points: fit.curve.map { NMRXY(x: $0.ppm,y: $0.residualRaw) }, color: .red)], marks: [], seeds: [], gain: gain, residual: true, gesture: { _,_ in }) }
        } else { Text("保存的区域不在当前谱轴内，请重选区域").foregroundColor(.orange) }
    }
    private func field(_ name: String, _ value: Binding<String>, _ width: CGFloat = 110) -> some View { TextField(name,text: value).textFieldStyle(.roundedBorder).frame(width: width).accessibilityLabel(Text(name)) }
    private var regionPane: some View {
        VStack(alignment: .leading) {
            Text("拖选谱段，或输入两端 ppm；不改变采样。")
            HStack { Text("边界"); field("低 ppm",$loText); field("高 ppm",$hiText); Button("应用区域",action: applyBand); Button("全谱") { record.cropOriginalPPM = nil; reload() } }
        }
    }
    private var gainPane: some View {
        VStack(alignment: .leading) {
            Text("仅缩放显示；积分、参考和拟合始终使用未缩放强度。")
            HStack { Text("区内最大绝对值 →"); field("强度目标",$gainTarget); Button("应用缩放") { run { record.displayGain = try trace.displayGain(in: checkedBand(), target: nmrParse(gainTarget)) } }; Button("还原强度") { record.displayGain = nil }; Text("倍率 \(nmrText(gain))") }
        }
    }
    private func measure(reference: Bool) {
        run { let target = reference ? try nmrParse(refTarget) : nil; let e = try NMRAnalysis.integrate(trace, in: checkedBand(), referenceTarget: target, ports: ports); record.integrals.append(e); notice = reference ? "参考和区间已保存" : "积分已保存" }
    }
    private var integralPane: some View {
        VStack(alignment: .leading) {
            HStack { Button("积分本区") { measure(reference: false) }; Divider().frame(height: 18); Text("参考值"); field("正参考值",$refTarget); Button("设本区为参考") { measure(reference: true) } }
            Text("沿用主谱的有符号积分及已有参考；保留每次测量时的原值。")
            ForEach(Array(record.integrals.suffix(5).indices),id: \.self) { i in
                let a = record.integrals[i]; let rel = a.relative.map { nmrText($0.value) } ?? "无参考"
                Text("\(nmrText(a.calibratedPPM.lo))…\(nmrText(a.calibratedPPM.hi)) ppm　原面积 \(nmrText(a.rawSignedArea)) 强度·ppm　相对 \(rel)\(a.setsReference ? "（参考）" : "")")
            }.font(.caption.monospacedDigit())
        }
    }
    @ViewBuilder private func positions(seed: Bool) -> some View {
        let list = seed ? record.seedsOriginalPPM : record.marksOriginalPPM
        HStack { Text(seed ? "初值 ppm" : "标位 ppm"); field("位置 ppm",$position); Button(seed ? "加初值" : "加标峰") { run { try addPosition(nmrParse(position),seed: seed) } }; Text("也可点谱线").foregroundColor(.secondary) }
        ScrollView(.horizontal) { HStack { ForEach(list.indices,id: \.self) { i in
            let x = ports.fromOriginalPPM(list[i]); Button("\(nmrText(x))\(window?.contains(x) == true ? "" : " 区外") ×") {
                if seed { record.seedsOriginalPPM.remove(at: i) } else { record.marksOriginalPPM.remove(at: i) }
            }.help(seed ? "删除初值" : "删除标峰")
        } } }.frame(height: list.isEmpty ? 2 : 32)
    }
    private func startFit() {
        guard job == nil else { return }
        run {
            let w = try checkedBand(), ss = active(record.seedsOriginalPPM,w), shape = record.shape, mix = record.mix, t = trace, id = UUID()
            guard (1...6).contains(ss.count) else { throw NMRAnalysisError.message("请在区内设置 1–6 个初值") }
            job = id; discard = false
            DispatchQueue.global(qos: .userInitiated).async {
                let answer = Result { try NMRAnalysis.fit(t,in: w,seeds: ss,shape: shape,mix: mix) }
                DispatchQueue.main.async {
                    guard job == id else { return }; job = nil
                    guard !discard else { notice = "输入已变，未采用拟合"; return }
                    switch answer { case .success(let f): record.fit = f; notice = "拟合："+f.status.label; case .failure(let error): notice = error.localizedDescription }
                }
            }
        }
    }
    @ViewBuilder private func fitDetails(_ f: NMRFit) -> some View {
        let here = window.flatMap { currentFit($0) } != nil
        Text("\(here ? "当前拟合" : "历史拟合（不叠图）")：\(f.status.label)　\(f.shape.label)　组分 \(f.componentCount)　迭代 \(f.iterations)　\(f.flags.joined(separator: "；"))")
        if let rms = f.weightedRMSRaw, let b = f.backgroundAtMidRaw, let s = f.slopeRawPerPPM { Text("加权均方根 \(nmrText(rms))　窗中背景 \(nmrText(b))　斜率 \(nmrText(s)) 强度/ppm") }
        ForEach(f.components.indices,id: \.self) { i in let c = f.components[i]
            Text("\(i+1)　中心 \(nmrText(c.centerPPM)) ppm　峰高 \(nmrText(c.heightRaw))　半高全宽 \(nmrText(c.fwhmPPM)) ppm　全线模型面积 \(nmrText(c.fullModelAreaRawPPM)) 强度·ppm")
        }
    }
    private var fitPane: some View {
        VStack(alignment: .leading) {
            positions(seed: true)
            HStack { Picker("峰形",selection: $record.shape) { ForEach(NMRShape.allCases,id: \.self) { Text($0.label).tag($0) } }.frame(width: 165)
                if record.shape == .pseudoVoigt { Text("洛伦兹比例"); Slider(value: $record.mix,in: 0...1,step: 0.05).frame(width: 100); Text(nmrText(record.mix)) }
                Button(job == nil ? "拟合本区" : "拟合中",action: startFit).disabled(job != nil)
            }
            Text("橙线为初值；每组分独立峰宽，共用峰形与线性背景。模型面积不是区间积分。").font(.caption)
            if let f = record.fit { fitDetails(f).font(.caption.monospacedDigit()) }
        }
    }
    private func readLines() {
        run { let w = try checkedBand(); let l = try NMRAnalysis.readLines(trace,in: w,marks: active(record.marksOriginalPPM,w),manualMHz: record.manualMHz,testFirstOrder: firstOrder); record.lines = l; notice = "读数已保存" }
    }
    private func applyFrequency() {
        run { if frequency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { record.manualMHz = nil } else { let v = try nmrParse(frequency); guard v > 0 else { throw NMRAnalysisError.message("观测频率须为正") }; record.manualMHz = v }; notice = "频率已更新，请重读线组" }
    }
    @ViewBuilder private func lineDetails(_ l: NMRLineReadout) -> some View {
        let current = window == l.windowPPM && l.traceKey == trace.key && l.markedPPM == active(record.marksOriginalPPM,l.windowPPM) && l.observeMHz == (record.manualMHz ?? trace.observeMHz) && l.testFirstOrder == firstOrder
        Text("\(current ? "当前读数" : "历史读数")　外线中点 \(nmrText(l.apparentMidPPM)) ppm　\(l.resolved ? "线谷可辨" : "未证实多线分辨")")
        if let v = l.twoMarkSpacingPPM { let h = l.twoMarkSpacingHz.map { " = "+nmrText($0)+" Hz" } ?? ""; Text("两标间距（非 J 归属） \(nmrText(v)) ppm\(h)") }
        if let p = l.compatiblePattern { let j = l.inferredJHz.map { "　条件推断 J ≈ "+nmrText($0)+" Hz" } ?? ""; Text("一阶相容：\(p.rawValue)\(j)") }
        if !l.apparentFWHMPPM.isEmpty { Text("表观半高全宽（ppm）：" + l.apparentFWHMPPM.map(nmrText).joined(separator: "，")) }
        if let f = l.observeMHz { Text("读数所用本核频率：\(nmrText(f)) MHz（\(l.frequencySource == "manual" ? "手动" : "元数据")）") }
        Text(l.flags.joined(separator: "；"))
    }
    private var linesPane: some View {
        VStack(alignment: .leading) {
            HStack { Text("本核 MHz"); field("手动频率",$frequency); Button("应用频率",action: applyFrequency); Text("留空沿用元数据：" + (trace.observeMHz.map(nmrText) ?? "缺失")) }
            Toggle("按孤立一阶线组检验",isOn: $firstOrder)
            HStack { Button("读取区内标峰",action: readLines); Text("仅检验 d / t / q；间距偏差 ≤5%，相对线强偏差 ≤22%。").font(.caption) }
            if let l = record.lines { lineDetails(l).font(.caption.monospacedDigit()) }
            if let f = record.fit { fitDetails(f).font(.caption.monospacedDigit()) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("区域分析").font(.headline); Spacer(); Button("导出分析 CSV") { document = NMRCSVDocument(record.analysisCSV(currentKey: trace.key)); saving = true }; Button("完成") { dismiss() } }
            Picker("工具",selection: $page) { ForEach(NMRPage.allCases,id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            plots
            Divider()
            ScrollView { VStack(alignment: .leading,spacing: 6) {
                switch page { case .region: regionPane; case .gain: gainPane; case .integral: integralPane; case .fit: fitPane; case .marks: positions(seed: false); Text("紫线为人工标位；读线时仅使用区内标峰。").font(.caption); case .lines: linesPane }
            }.frame(maxWidth: .infinity,alignment: .leading) }
            Text(notice.isEmpty ? "原轴保存边界和标位；各工具可独立使用。" : notice).foregroundColor(.secondary).textSelection(.enabled)
        }
        .padding().frame(minWidth: 760,idealWidth: 830,minHeight: 540,idealHeight: 610)
        .onAppear { frequency = record.manualMHz.map { String($0) } ?? ""; firstOrder = record.lines?.testFirstOrder ?? false; reload() }
        .onDisappear { invalidateJob() }
        .onChange(of: trace.key) { _ in reload() }.onChange(of: record.cropOriginalPPM) { _ in reload() }
        .onChange(of: record.seedsOriginalPPM) { _ in invalidateJob() }.onChange(of: record.shape) { _ in invalidateJob() }.onChange(of: record.mix) { _ in invalidateJob() }
        .fileExporter(isPresented: $saving,document: document,contentType: .commaSeparatedText,defaultFilename: "区域分析") { result in
            switch result { case .success: notice = "分析 CSV 已导出"; case .failure(let e): notice = e.localizedDescription }
        }
    }
}
