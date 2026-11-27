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
    var selectedBandID: UUID? = nil

    func isSelectedBand(_ index: Int) -> Bool {
        guard bands.indices.contains(index) else { return false }
        if let selectedBandID {
            return bandIDs.indices.contains(index) && bandIDs[index] == selectedBandID
        }
        return bands[index] == selectedBand
    }

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
        // Keep two integral lanes at the 400 pt reference/test viewport after
        // enlarging the axis and integral fonts; overlapping bands remain reachable.
        let bottom = floor(min(h * 0.40, min(174, 76 + h * 0.13 + narrow * 12)))
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
    @Environment(\.colorScheme) private var colorScheme
    var data: PlotState
    var tool: Tool
    var select: (Tool, ClosedRange<Double>) -> Void
    var peakBox: ((NMRRawBox, Bool) throws -> Void)? = nil
    var annotations: [NMROverlayGroup] = []
    var rawOffset = 0.0
    var axisID = ""
    var reportProblem: (String) -> Void = { _ in }
    var onIntegralSelection: ((UUID) -> Void)? = nil
    var integralEditing: ((UUID) -> PlotIntegralEdit?)? = nil

    private func updateAppearance(_ view: PlotView) {
        let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != name {
            // Local to the hosted screen view. Never change NSApp, defaults,
            // or the independent white export renderer's appearance.
            view.appearance = NSAppearance(named: name)
            view.needsDisplay = true
        }
    }

    func makeNSView(context: Context) -> PlotView {
        let view = PlotView()
        updateAppearance(view)
        return view
    }

    func updateNSView(_ view: PlotView, context: Context) {
        updateAppearance(view)
        view.onIntegralSelection = onIntegralSelection
        view.integralEditing = integralEditing
        view.tool = tool
        view.update(data)
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
    var tool = Tool.zoom {
        didSet {
            if tool != oldValue {
                cancelIntegralDrag()
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
            }
        }
    }
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

    var integralEditing: ((UUID) -> PlotIntegralEdit?)? {
        didSet {
            if integralEditing == nil { cancelIntegralDrag() }
            if (oldValue == nil) != (integralEditing == nil) {
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
            }
        }
    }

    var state: PlotState? {
        didSet {
            let axesChanged = oldValue?.window != state?.window ||
                oldValue?.spectrum.ppm != state?.spectrum.ppm ||
                oldValue?.spectrum.real != state?.spectrum.real
            if axesChanged || oldValue?.gain != state?.gain ||
                oldValue?.bands != state?.bands || oldValue?.bandIDs != state?.bandIDs ||
                oldValue?.bandLabels != state?.bandLabels {
                cancelIntegralDrag()
            }
            if axesChanged {
                cachedOrdinate = nil
                cachedTrace = nil
            }
            if axesChanged || oldValue?.peaks != state?.peaks ||
                oldValue?.bands != state?.bands || oldValue?.bandLabels != state?.bandLabels ||
                oldValue?.bandIDs != state?.bandIDs || oldValue?.gain != state?.gain ||
                oldValue?.selectedPeak != state?.selectedPeak ||
                oldValue?.selectedBand != state?.selectedBand ||
                oldValue?.selectedBandID != state?.selectedBandID || oldValue?.title != state?.title {
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
    private struct IntegralDrag {
        let cap: PlotAnnotationLayout.IntegralCap
        let edit: PlotIntegralEdit
        let point: CGPoint
        let viewBounds: CGRect
        let window: NSWindow
        let tool: Tool
        let viewport: ClosedRange<Double>
        let endpointLimits: ClosedRange<Double>
        var range: ClosedRange<Double>
        var moved = false
    }
    private var integralDrag: IntegralDrag?
    private var consumesIntegralDrag = false
    private var integralPreview: PlotState? {
        didSet {
            cachedLayout = nil
            needsLayout = true
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var displayedState: PlotState? { integralPreview ?? state }
    private var plotTracking: NSTrackingArea?
    private var forPDF = false

    override var acceptsFirstResponder: Bool { true }
    var field: CGRect { PlotGeometry.field(size: bounds.size) }

    func update(_ data: PlotState) {
        state = data
        if let drag = integralDrag, !integralDragIsCurrent(drag) { cancelIntegralDrag() }
    }

    private func integralDragIsCurrent(_ drag: IntegralDrag) -> Bool {
        window === drag.window && window?.firstResponder === self &&
            bounds == drag.viewBounds && tool == drag.tool && drag.edit.isCurrent()
    }

    private func beginIntegralDrag(at point: CGPoint) -> Bool {
        guard tool == .zoom || tool == .integral,
              let factory = integralEditing, let s = state, let g = geometry,
              let cap = plan(s, g).integralCap(at: point, state: s),
              let edit = factory(cap.id), edit.isCurrent(),
              s.bands[cap.index] == edit.bounds, let window else { return false }
        let width = edit.bounds.upperBound - edit.bounds.lowerBound
        guard width.isFinite, width > 0 else { return false }
        let endpoint = cap.upper ? edit.bounds.upperBound : edit.bounds.lowerBound
        let index = s.spectrum.nearest(endpoint)
        let neighbor = index + 1 < s.spectrum.ppm.count ? index + 1 : max(0, index - 1)
        let spacing = abs(s.spectrum.ppm[index] - s.spectrum.ppm[neighbor])
        let minimum = min(width, max(spacing * 0.1, max(1, abs(endpoint)) * Double.ulpOfOne * 8))
        var low = max(s.window.lowerBound, edit.limits.lowerBound)
        var high = min(s.window.upperBound, edit.limits.upperBound)
        if cap.upper { low = max(low, edit.bounds.lowerBound + minimum) }
        else { high = min(high, edit.bounds.upperBound - minimum) }
        guard low.isFinite, high.isFinite, low <= high,
              let preview = edit.preview(edit.bounds), window.makeFirstResponder(self) else { return false }
        integralDrag = IntegralDrag(cap: cap, edit: edit, point: point, viewBounds: bounds,
                                    window: window, tool: tool, viewport: s.window,
                                    endpointLimits: low...high, range: edit.bounds)
        consumesIntegralDrag = true
        integralPreview = preview
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(integralWindowChanged(_:)), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(integralWindowChanged(_:)),
                           name: NSApplication.didResignActiveNotification, object: nil)
        return true
    }

    private func resizeIntegral(to point: CGPoint) {
        guard var drag = integralDrag else { return }
        guard integralDragIsCurrent(drag), point.x.isFinite else { cancelIntegralDrag(); return }
        let dx = point.x - drag.point.x
        if !drag.moved && abs(dx) < 2 { return }
        drag.moved = true
        let original = drag.edit.bounds
        let endpoint = drag.cap.upper ? original.upperBound : original.lowerBound
        let proposed = endpoint - Double(dx / field.width) *
            (drag.viewport.upperBound - drag.viewport.lowerBound)
        let value = min(drag.endpointLimits.upperBound, max(drag.endpointLimits.lowerBound, proposed))
        // Returning to the original mouse position also restores its exact doubles.
        let next = dx == 0 ? original : (drag.cap.upper ? original.lowerBound...value : value...original.upperBound)
        guard next.lowerBound.isFinite, next.upperBound.isFinite, next.lowerBound < next.upperBound else { return }
        if next != drag.range {
            guard let preview = drag.edit.preview(next) else { return }
            drag.range = next
            integralPreview = preview
        }
        integralDrag = drag
        // The tooltip also updates when a moved endpoint is clamped and the
        // preview range itself does not change. No layout invalidation needed.
        needsDisplay = true
    }

    private func finishIntegralDrag() {
        let drag = integralDrag
        let valid = drag.map { integralDragIsCurrent($0) } ?? false
        consumesIntegralDrag = false
        cancelIntegralDrag()
        guard let drag, valid else { return }
        if drag.range != drag.edit.bounds { drag.edit.commit(drag.range) }
        else { onIntegralSelection?(drag.cap.id) }
    }

    private func cancelIntegralDrag() {
        integralDrag = nil
        if integralPreview != nil { integralPreview = nil }
        // Keep consumesIntegralDrag until mouse-up: a cancelled cap drag must
        // never fall through into zoom, peak boxing or new-integral creation.
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSApplication.didResignActiveNotification] {
            center.removeObserver(self, name: name, object: nil)
        }
    }

    @objc private func integralWindowChanged(_ notification: Notification) { cancelIntegralDrag() }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { cancelIntegralDrag() }
        return accepted
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { cancelIntegralDrag() }
        super.setFrameSize(newSize)
    }

    override func setBoundsSize(_ newSize: NSSize) {
        if newSize != bounds.size { cancelIntegralDrag() }
        super.setBoundsSize(newSize)
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        if newOrigin != bounds.origin { cancelIntegralDrag() }
        super.setBoundsOrigin(newOrigin)
    }

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
            if let s = displayedState, let g = geometry { _ = plan(s, g) }
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
        guard let s = displayedState, let g = geometry else { return }
        let p = plan(s, g)
        if onIntegralSelection != nil {
            for b in p.integrals where b.id != nil {
                for hit in [b.valueHit, b.bracketHit] {
                    let r = hit.intersection(p.regions.gutter)
                    if !r.isNull && !r.isEmpty { addCursorRect(r, cursor: .pointingHand) }
                }
            }
        }
        if integralEditing != nil, tool == .zoom || tool == .integral {
            for cap in p.integralCaps(state: s) {
                let r = cap.hit.intersection(p.regions.gutter)
                if !r.isNull && !r.isEmpty { addCursorRect(r, cursor: .resizeLeftRight) }
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
              let s = displayedState, let g = geometry else { return nil }
        return plan(s, g).integralID(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        cancelIntegralDrag()
        consumesIntegralDrag = false
        start = nil
        end = nil
        armedIntegral = nil
        if boxes.mouseDown(event, in: self) { window?.makeFirstResponder(self); return }
        let p = convert(event.locationInWindow, from: nil)
        if beginIntegralDrag(at: p) { return }
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
        if consumesIntegralDrag {
            resizeIntegral(to: convert(event.locationInWindow, from: nil))
            return
        }
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
        if consumesIntegralDrag { finishIntegralDrag(); return }
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
            if consumesIntegralDrag { cancelIntegralDrag(); return }
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
        cancelIntegralDrag()
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
        let target = (w.upperBound - w.lowerBound) / Double(max(2, min(192, floor(r.width / 96))))
        let unit = pow(10.0, floor(log10(target)))
        let step = ([1.0, 2, 5, 10].first { $0 * unit >= target } ?? 10) * unit
        var tickLabelBottom = axis - 6
        if step.isFinite, step > 0 {
            let first = ceil(w.lowerBound / step) * step
            let digits = Int(min(9, max(0, -floor(log10(step)))))
            let font = PlotInk.font(16)
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
                let y = axis - 6 - size.height
                // Ticks arrive right to left. Keep the grid even when two numbers won't fit.
                if y >= bounds.minY, left + size.width <= labelLimit {
                    PlotInk.draw(text, at: CGPoint(x: left, y: y), font: font, color: c.axis)
                    labelLimit = left - 8
                    tickLabelBottom = min(tickLabelBottom, y)
                }
            }
        }
        PlotInk.line(CGPoint(x: r.minX, y: g.y(0)), CGPoint(x: r.maxX, y: g.y(0)), c.grid, 0.7)
        PlotInk.line(CGPoint(x: r.minX, y: axis), CGPoint(x: r.maxX, y: axis), c.axis, 0.85)
        let font = PlotInk.font(17)
        let text = PlotInk.fitted("Chemical shift, δ (ppm)", font: font, width: r.width)
        let size = PlotInk.measure(text, font)
        if !text.isEmpty, size.height + 4 <= tickLabelBottom {
            PlotInk.draw(text, at: CGPoint(x: r.midX - size.width / 2, y: 2), font: font, color: c.axis)
        }
    }

    private func drawIntegralDragTooltip(_ s: PlotState, _ g: PlotGeometry, _ c: PlotPalette) {
        // Read the already validated live drag; never request a new preview,
        // change an endpoint, or synthesize a mark while drawing.
        guard let drag = integralDrag, drag.moved else { return }
        let r = g.field
        guard r.width > 48, r.height > 44 else { return }
        let value = drag.cap.upper ? drag.range.upperBound : drag.range.lowerBound
        let name = drag.cap.upper ? "上界" : "下界"
        let font = PlotInk.font(15)
        let text = PlotInk.fitted("\(name) \(PlotInk.shift(value, digits: 6)) ppm",
                                  font: font, width: r.width - 24)
        guard !text.isEmpty else { return }
        let size = PlotInk.measure(text, font)
        let width = size.width + 16
        let x = min(r.maxX - width - 4, max(r.minX + 4, g.x(value, in: s.window) - width / 2))
        let box = CGRect(x: x, y: r.minY + 8, width: width, height: size.height + 10)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: r).addClip()
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        c.background.setFill()
        path.fill()
        c.selection.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1
        path.stroke()
        PlotInk.draw(text, at: CGPoint(x: box.minX + 8, y: box.minY + 5), font: font, color: c.text)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = !forPDF && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let c = PlotPalette(dark: dark, highContrast: contrast, forPDF: forPDF)
        let interactive = !forPDF && NSGraphicsContext.current?.isDrawingToScreen == true
        c.background.setFill()
        bounds.fill()
        guard let s = displayedState, let g = geometry else { return }
        let r = g.field, p = plan(s, g)
        drawAxes(s, g, p.regions, c)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        if interactive { p.drawSelectedIntegral(state: s, field: r, color: c.selection) }
        c.trace.setStroke()
        trace(s, g).stroke()
        p.drawTraceTicks(color: c.peak, selected: interactive ? s.selectedPeak : nil)
        NSGraphicsContext.restoreGraphicsState()

        p.drawPeakStrip(colors: c)
        p.drawIntegrals(state: s, color: c.integral, showSelection: interactive)
        if interactive, integralEditing != nil, tool == .zoom || tool == .integral {
            p.drawIntegralHandles(state: s, color: c.integral)
        }

        var heading = forPDF ? PlotInk.singleLine(s.title) : ""
        if interactive {
            boxes.draw(in: self)
            if let a = start, let b = end {
                c.selection.withAlphaComponent(0.12).setFill()
                CGRect(x: min(a, b), y: r.minY, width: abs(a - b), height: r.height).fill()
            }
            if integralDrag == nil, let h = hover, h >= r.minX, h <= r.maxX {
                let v = g.ppm(atX: h, in: s.window)
                PlotInk.line(CGPoint(x: h, y: r.minY), CGPoint(x: h, y: r.maxY),
                             c.selection.withAlphaComponent(0.45), 0.8)
                heading = String(format: "%.4f ppm   %.5g a.u.", locale: Locale.current,
                                 v, s.spectrum.real[s.spectrum.nearest(v)])
            }
            drawIntegralDragTooltip(s, g, c)
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
