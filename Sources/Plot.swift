import AppKit
import SwiftUI

enum Tool: String, CaseIterable { case zoom = "缩放", peak = "标峰", integral = "积分" }

struct PlotState {
    var spectrum: Spectrum
    var window: ClosedRange<Double>
    var peaks: [Double] = []
    var bands: [ClosedRange<Double>] = []
    var title: String
    var bandLabels: [String] = []
    var selectedPeak: Double? = nil
    var selectedBand: ClosedRange<Double>? = nil
    var gain: Double = 1
    var bandIDs: [UUID] = []

    var canPlot: Bool {
        let width = window.upperBound - window.lowerBound
        return width.isFinite && width > 0 &&
            !spectrum.real.isEmpty && spectrum.real.count == spectrum.ppm.count
    }

    var ordinateSpan: (low: Double, width: Double) {
        guard canPlot else { return (0, 1) }
        let first = spectrum.nearest(window.upperBound)
        let last = spectrum.nearest(window.lowerBound)
        var low = 0.0, high = 0.0
        for v in spectrum.real[min(first, last)...max(first, last)] where v.isFinite {
            low = min(low, v)
            high = max(high, v)
        }
        let width = high - low
        return (low, width.isFinite && width > 0 ? width : 1)
    }
}

struct PlotGeometry {
    let field: CGRect
    let ordinate: (low: Double, width: Double)

    // Deliberately a function of size alone. External solvent picking, the
    // flipped reference map and AppKit gestures must agree before any draw.
    static func field(size: CGSize) -> CGRect {
        let w = max(1, size.width), h = max(1, size.height)
        let side = min(30, floor(w * 0.08))
        let narrow = min(1, max(0, (680 - w) / 360))
        let top = floor(min(h * 0.31, min(134, 48 + h * 0.08 + narrow * 12)))
        let bottom = floor(min(h * 0.36, min(164, 58 + h * 0.12 + narrow * 12)))
        return CGRect(x: side, y: bottom, width: max(1, w - 2 * side),
                      height: max(1, h - bottom - top))
    }

    func x(_ ppm: Double, in window: ClosedRange<Double>) -> CGFloat {
        let fraction = (window.upperBound - ppm) / (window.upperBound - window.lowerBound)
        return field.minX + CGFloat(fraction) * field.width
    }

    func ppm(atX x: CGFloat, in window: ClosedRange<Double>) -> Double {
        if x <= field.minX { return window.upperBound }
        if x >= field.maxX { return window.lowerBound }
        return window.upperBound - Double((x - field.minX) / field.width) *
            (window.upperBound - window.lowerBound)
    }

    func ordinate(atY y: CGFloat) -> Double {
        ordinate.low + (Double((y - field.minY) / field.height) - 0.06) * ordinate.width / 0.87
    }

    func y(_ value: Double) -> CGFloat {
        field.minY + (0.06 + CGFloat((value - ordinate.low) / ordinate.width) * 0.87) * field.height
    }

    func referenceMap(height: CGFloat, window: ClosedRange<Double>, offset: Double, gain: Double) -> NRPlotMap? {
        guard gain.isFinite, gain != 0 else { return nil }
        let flipped = CGRect(x: field.minX, y: height - field.maxY, width: field.width, height: field.height)
        return NRPlotMap(rect: flipped, displayedLeft: window.upperBound, displayedRight: window.lowerBound,
                         offsetPPM: offset, intensityAtTop: ordinate(atY: field.maxY) / gain,
                         intensityAtBottom: ordinate(atY: field.minY) / gain)
    }
}

struct Plot: NSViewRepresentable {
    var data: PlotState
    var tool: Tool
    var select: (Tool, ClosedRange<Double>) -> Void
    var peakBox: ((NMRRawBox, Bool) throws -> Void)? = nil
    var annotations: [NMROverlayGroup] = []
    var rawOffset = 0.0
    var axisID = ""
    var reportProblem: (String) -> Void = { _ in }
    var onIntegralSelection: ((UUID) -> Void)? = nil

    func makeNSView(context: Context) -> PlotView { PlotView() }

    func updateNSView(_ view: PlotView, context: Context) {
        view.onIntegralSelection = onIntegralSelection
        view.update(data)
        view.tool = tool
        view.select = select
        view.boxes.enabled = { peakBox != nil }
        view.boxes.overlays = { annotations } // Retained API; not used as a drawing source.
        view.boxes.mapping = { [weak view] _ in view?.boxMap(offset: rawOffset, axisID: axisID) }
        view.boxes.commit = { box, clipped in try peakBox?(box, clipped) }
        view.boxes.report = reportProblem
        if peakBox == nil { view.boxes.cancel(in: view) }
    }
}

final class PlotView: NSView {
    let boxes = NMRPeakBoxInteraction()
    var tool = Tool.zoom
    var select: ((Tool, ClosedRange<Double>) -> Void)?
    var onIntegralSelection: ((UUID) -> Void)? {
        didSet {
            if (oldValue == nil) != (onIntegralSelection == nil) {
                cachedLayout = nil
                needsLayout = true
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    var state: PlotState? {
        didSet {
            let axesChanged = oldValue?.window != state?.window ||
                oldValue?.spectrum.ppm != state?.spectrum.ppm ||
                oldValue?.spectrum.real != state?.spectrum.real
            if axesChanged {
                cachedOrdinate = nil
                cachedTrace = nil
            }
            if axesChanged || oldValue?.peaks != state?.peaks ||
                oldValue?.bands != state?.bands || oldValue?.bandLabels != state?.bandLabels ||
                oldValue?.bandIDs != state?.bandIDs || oldValue?.gain != state?.gain ||
                oldValue?.selectedPeak != state?.selectedPeak ||
                oldValue?.selectedBand != state?.selectedBand || oldValue?.title != state?.title {
                cachedLayout = nil
                needsLayout = true
                window?.invalidateCursorRects(for: self)
            }
            needsDisplay = true
        }
    }

    private var cachedOrdinate: (low: Double, width: Double)?
    private var cachedTrace: (field: CGRect, path: NSBezierPath)?
    private var cachedLayout: (size: CGSize, plan: PlotAnnotationLayout)?
    private var start: CGFloat?, end: CGFloat?, hover: CGFloat?
    private var armedIntegral: (id: UUID, point: CGPoint)?
    private var plotTracking: NSTrackingArea?
    private var forPDF = false

    override var acceptsFirstResponder: Bool { true }
    var field: CGRect { PlotGeometry.field(size: bounds.size) }

    func update(_ data: PlotState) { state = data }

    private var geometry: PlotGeometry? {
        guard let s = state, s.canPlot else { return nil }
        let span = cachedOrdinate ?? s.ordinateSpan
        cachedOrdinate = span
        return PlotGeometry(field: field, ordinate: span)
    }

    func boxMap(offset: Double, axisID: String) -> NMRPlotMap? {
        guard let s = state, let g = geometry, s.gain.isFinite, s.gain != 0 else { return nil }
        let r = g.field
        return NMRPlotMap(plot: r, visible: bounds.intersection(visibleRect),
                          ppmAtMin: s.window.upperBound - offset, ppmAtMax: s.window.lowerBound - offset,
                          rawAmpAtMin: g.ordinate(atY: r.minY) / s.gain,
                          rawAmpAtMax: g.ordinate(atY: r.maxY) / s.gain, epoch: axisID)
    }

    func ppm(_ x: CGFloat) -> Double {
        guard let s = state, let g = geometry else { return 0 }
        return g.ppm(atX: x, in: s.window)
    }

    private func plan(_ s: PlotState, _ g: PlotGeometry) -> PlotAnnotationLayout {
        if let c = cachedLayout, c.size == bounds.size { return c.plan }
        let p = PlotAnnotationLayout(s, geometry: g, size: bounds.size)
        cachedLayout = (bounds.size, p)
        if !forPDF { installAccessibility(s, p) }
        return p
    }

    private func installAccessibility(_ s: PlotState, _ p: PlotAnnotationLayout) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let title = PlotInk.singleLine(s.title)
        setAccessibilityLabel(title.isEmpty ? "NMR spectrum" : title)
        setAccessibilityHelp(p.omissionNote.isEmpty ? nil : p.omissionNote)

        var actions: [NSAccessibilityCustomAction] = []
        if onIntegralSelection != nil {
            for b in p.integrals {
                guard let id = b.id else { continue }
                let range = s.bands[b.index]
                let name = "选择积分 \(PlotInk.shift(range.upperBound, digits: 4)) – " +
                    "\(PlotInk.shift(range.lowerBound, digits: 4)) ppm: \(b.fullText)"
                actions.append(NSAccessibilityCustomAction(name: name, handler: { [weak self] in
                    guard let self, let action = self.onIntegralSelection,
                          let current = self.state, let geometry = self.geometry,
                          self.plan(current, geometry).integrals.contains(where: { $0.id == id })
                    else { return false }
                    action(id)
                    return true
                }))
            }
        }
        setAccessibilityCustomActions(actions)
    }

    override func layout() {
        super.layout()
        if !forPDF {
            if let s = state, let g = geometry { _ = plan(s, g) }
            else { setAccessibilityCustomActions([]) }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let plotTracking { removeTrackingArea(plotTracking) }
        let area = NSTrackingArea(rect: field, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        plotTracking = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(field, cursor: .crosshair)
        guard onIntegralSelection != nil, let s = state, let g = geometry else { return }
        let p = plan(s, g)
        for b in p.integrals where b.id != nil {
            for hit in [b.valueHit, b.bracketHit] {
                let r = hit.intersection(p.regions.gutter)
                if !r.isNull && !r.isEmpty { addCursorRect(r, cursor: .pointingHand) }
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = field.contains(p) ? p.x : nil
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    private func integral(at point: CGPoint) -> UUID? {
        guard onIntegralSelection != nil, point.y < field.minY,
              let s = state, let g = geometry else { return nil }
        return plan(s, g).integralID(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        start = nil
        end = nil
        armedIntegral = nil
        if boxes.mouseDown(event, in: self) { window?.makeFirstResponder(self); return }
        let p = convert(event.locationInWindow, from: nil)
        if let id = integral(at: p) {
            armedIntegral = (id, p)
            window?.makeFirstResponder(self)
            return
        }
        guard field.contains(p), state?.canPlot == true else { return }
        start = p.x
        end = p.x
    }

    override func mouseDragged(with event: NSEvent) {
        if boxes.mouseDragged(event, in: self) { return }
        let p = convert(event.locationInWindow, from: nil)
        if let a = armedIntegral {
            if hypot(p.x - a.point.x, p.y - a.point.y) > 4 { armedIntegral = nil }
            return
        }
        guard start != nil else { return }
        end = min(field.maxX, max(field.minX, p.x))
        hover = end
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if boxes.mouseUp(event, in: self) { return }
        let p = convert(event.locationInWindow, from: nil)
        if let a = armedIntegral {
            armedIntegral = nil
            if hypot(p.x - a.point.x, p.y - a.point.y) <= 4, integral(at: p) == a.id {
                onIntegralSelection?(a.id)
            }
            return
        }
        guard let x = start else { return }
        start = nil
        end = nil
        needsDisplay = true
        guard state?.canPlot == true else { return }
        if tool == .peak {
            select?(.peak, ppm(p.x + 5)...ppm(p.x - 5))
        } else if abs(x - p.x) > 4 {
            let a = ppm(p.x), b = ppm(x)
            select?(tool, min(a, b)...max(a, b))
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if boxes.cancel(in: self) { return }
            if start != nil || armedIntegral != nil {
                start = nil; end = nil; armedIntegral = nil
                needsDisplay = true
                return
            }
        }
        super.keyDown(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        boxes.cancel(in: self)
        start = nil; end = nil; hover = nil; armedIntegral = nil
        super.viewWillMove(toWindow: newWindow)
    }

    func label(_ value: String, at point: CGPoint, size: CGFloat, color: NSColor, centered: Bool = false) {
        let font = PlotInk.font(size)
        let dx = centered ? PlotInk.measure(value, font).width / 2 : 0
        PlotInk.draw(value, at: CGPoint(x: point.x - dx, y: point.y), font: font, color: color)
    }

    private func trace(_ s: PlotState, _ g: PlotGeometry) -> NSBezierPath {
        if let c = cachedTrace, c.field == g.field { return c.path }
        let data = s.spectrum, w = s.window
        var first = data.nearest(w.upperBound), last = data.nearest(w.lowerBound)
        // Include the segment crossing each crop boundary; clip at draw time.
        if first > 0 && data.ppm[first] < w.upperBound { first -= 1 }
        if last < data.ppm.count - 1 && data.ppm[last] > w.lowerBound { last += 1 }

        let path = NSBezierPath()
        var penDown = false
        var j = first
        while j <= last {
            let column = floor(g.x(data.ppm[j], in: w))
            var k = j + 1, a = j, b = j
            while k <= last && floor(g.x(data.ppm[k], in: w)) == column {
                if data.real[k] < data.real[a] { a = k }
                if data.real[k] > data.real[b] { b = k }
                k += 1
            }
            // Both extrema, in acquisition order, including for negative lines.
            var previous = -1
            for i in [j, min(a, b), max(a, b), k - 1] where i != previous {
                previous = i
                let p = CGPoint(x: g.x(data.ppm[i], in: w), y: g.y(data.real[i]))
                guard p.x.isFinite, p.y.isFinite else { penDown = false; continue }
                if penDown { path.line(to: p) } else { path.move(to: p); penDown = true }
            }
            j = k
        }
        path.lineWidth = 1.25
        cachedTrace = (g.field, path)
        return path
    }

    private func drawAxes(_ s: PlotState, _ g: PlotGeometry, _ regions: PlotRegions, _ c: PlotPalette) {
        let r = g.field, w = s.window, axis = regions.axisY
        let target = (w.upperBound - w.lowerBound) / Double(max(2, min(192, floor(r.width / 72))))
        let unit = pow(10.0, floor(log10(target)))
        let step = ([1.0, 2, 5, 10].first { $0 * unit >= target } ?? 10) * unit
        var tickLabelBottom = axis - 4
        if step.isFinite, step > 0 {
            let first = ceil(w.lowerBound / step) * step
            let digits = Int(min(9, max(0, -floor(log10(step)))))
            let font = PlotInk.font(12)
            let hair: CGFloat = forPDF ? 0.65 : 1 / max(1, window?.backingScaleFactor ?? 1)
            var labelLimit = bounds.maxX
            for i in 0..<196 {
                let tick = first + Double(i) * step
                guard tick.isFinite, tick <= w.upperBound + step * 1e-8 else { break }
                let x = g.x(tick, in: w)
                PlotInk.line(CGPoint(x: x, y: r.minY), CGPoint(x: x, y: r.maxY), c.grid, hair)
                PlotInk.line(CGPoint(x: x, y: axis - 3), CGPoint(x: x, y: axis), c.axis, 0.7)
                let text = PlotInk.shift(abs(tick) < step * 1e-6 ? 0 : tick, digits: digits)
                let size = PlotInk.measure(text, font)
                let left = max(bounds.minX, min(bounds.maxX - size.width, x - size.width / 2))
                let y = axis - 4 - size.height
                // Ticks arrive right to left. Keep the grid even when two numbers won't fit.
                if y >= bounds.minY, left + size.width <= labelLimit {
                    PlotInk.draw(text, at: CGPoint(x: left, y: y), font: font, color: c.axis)
                    labelLimit = left - 3
                    tickLabelBottom = min(tickLabelBottom, y)
                }
            }
        }
        PlotInk.line(CGPoint(x: r.minX, y: g.y(0)), CGPoint(x: r.maxX, y: g.y(0)), c.grid, 0.7)
        PlotInk.line(CGPoint(x: r.minX, y: axis), CGPoint(x: r.maxX, y: axis), c.axis, 0.85)
        let font = PlotInk.font(13)
        let text = PlotInk.fitted("Chemical shift, δ (ppm)", font: font, width: r.width)
        let size = PlotInk.measure(text, font)
        if !text.isEmpty, size.height + 4 <= tickLabelBottom {
            PlotInk.draw(text, at: CGPoint(x: r.midX - size.width / 2, y: 2), font: font, color: c.axis)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = !forPDF && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let c = PlotPalette(dark: dark, highContrast: contrast, forPDF: forPDF)
        c.background.setFill()
        bounds.fill()
        guard let s = state, let g = geometry else { return }
        let r = g.field, p = plan(s, g)
        drawAxes(s, g, p.regions, c)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        c.trace.setStroke()
        trace(s, g).stroke()
        p.drawTraceTicks(color: c.peak, selected: forPDF ? nil : s.selectedPeak)
        NSGraphicsContext.restoreGraphicsState()

        p.drawPeakStrip(colors: c)
        p.drawIntegrals(state: s, color: PlotInk.integralGreen(dark: dark, contrast: contrast),
                        showSelection: !forPDF)

        var heading = forPDF ? PlotInk.singleLine(s.title) : ""
        if !forPDF {
            boxes.draw(in: self)
            if let a = start, let b = end {
                c.selection.withAlphaComponent(0.12).setFill()
                CGRect(x: min(a, b), y: r.minY, width: abs(a - b), height: r.height).fill()
            }
            if let h = hover, h >= r.minX, h <= r.maxX {
                let v = g.ppm(atX: h, in: s.window)
                PlotInk.line(CGPoint(x: h, y: r.minY), CGPoint(x: h, y: r.maxY),
                             c.selection.withAlphaComponent(0.45), 0.8)
                heading = String(format: "%.4f ppm   %.5g a.u.", locale: Locale.current,
                                 v, s.spectrum.real[s.spectrum.nearest(v)])
            }
        }
        p.drawHeader(heading, color: c.text)
    }

    static func pdf(_ state: PlotState, to url: URL) throws {
        let size = CGRect(x: 0, y: 0, width: 900, height: 450)
        var box = size
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output),
              let cg = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw NMRError("Could not create the PDF.") }
        cg.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        let view = PlotView(frame: size)
        view.forPDF = true
        view.update(state)
        view.draw(size)
        NSGraphicsContext.restoreGraphicsState()
        cg.endPDFPage()
        cg.closePDF()
        try (output as Data).write(to: url, options: .atomic)
    }
}
