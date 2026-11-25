import AppKit
import SwiftUI

// Axis-aligned plot in the SAME local coordinate system used by draw(_:).
// The two calibrations are independent; neither endpoint has a prescribed sign.
struct NMRLocalAxis: Equatable {
    let p0: CGFloat, p1: CGFloat, v0: Double, v1: Double
    init?(_ p0: CGFloat, _ p1: CGFloat, _ v0: Double, _ v1: Double) {
        guard p0.isFinite, p1.isFinite, v0.isFinite, v1.isFinite, (p1-p0).isFinite, (v1-v0).isFinite, p0 != p1, v0 != v1 else { return nil }
        self.p0 = p0; self.p1 = p1; self.v0 = v0; self.v1 = v1
    }
    func raw(_ p: CGFloat) -> Double { v0 + Double((p-p0)/(p1-p0))*(v1-v0) }
    func local(_ v: Double) -> CGFloat { p0 + CGFloat((v-v0)/(v1-v0))*(p1-p0) }
}

struct NMRPlotMap: Equatable {
    let clip: CGRect
    let ppmOnX: Bool
    let ppmAxis: NMRLocalAxis, ampAxis: NMRLocalAxis
    let epoch: String // acquisition/shape/tool/coordinate epoch; see integration
    init?(plot: CGRect, visible: CGRect, ppmOnX: Bool = true, ppmAtMin: Double, ppmAtMax: Double, rawAmpAtMin: Double, rawAmpAtMax: Double, epoch: String) {
        let c = plot.intersection(visible)
        guard plot.width > 0, plot.height > 0, !c.isNull, c.width > 0, c.height > 0,
              let x = NMRLocalAxis(ppmOnX ? plot.minX : plot.minY,ppmOnX ? plot.maxX : plot.maxY,ppmAtMin,ppmAtMax),
              let y = NMRLocalAxis(ppmOnX ? plot.minY : plot.minX,ppmOnX ? plot.maxY : plot.maxX,rawAmpAtMin,rawAmpAtMax) else { return nil }
        clip = c; self.ppmOnX = ppmOnX; ppmAxis = x; ampAxis = y; self.epoch = epoch
    }
    func contains(_ p: CGPoint) -> Bool { p.x >= clip.minX && p.x <= clip.maxX && p.y >= clip.minY && p.y <= clip.maxY }
    func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x:max(clip.minX,min(clip.maxX,p.x)),y:max(clip.minY,min(clip.maxY,p.y))) }
    func raw(_ p: CGPoint) -> (ppm: Double, amp: Double) { (ppmAxis.raw(ppmOnX ? p.x : p.y),ampAxis.raw(ppmOnX ? p.y : p.x)) }
    func local(ppm: Double, amp: Double) -> CGPoint {
        let u = ppmAxis.local(ppm), v = ampAxis.local(amp)
        return CGPoint(x:ppmOnX ? u : v,y:ppmOnX ? v : u)
    }
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect { CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y)) }
    func box(start: CGPoint, end: CGPoint) -> NMRRawBox? {
        guard contains(start) else { return nil }
        let a = raw(start), b = raw(clamp(end)); let box = NMRRawBox(ppm:NMRSpan(a.ppm,b.ppm),intensity:NMRSpan(a.amp,b.amp))
        return box.valid ? box : nil
    }
    func localRect(_ b: NMRRawBox) -> CGRect { Self.rect(local(ppm:b.ppm.low,amp:b.intensity.low),local(ppm:b.ppm.high,amp:b.intensity.high)) }
}

struct NMROverlayGroup {
    let group: NMRPeakGroup
    let selected: Bool
    let stale: Bool
}

// One instance per plot. All callbacks are on the AppKit event/draw thread.
final class NMRPeakBoxInteraction {
    var mapping: (NSView) -> NMRPlotMap? = { _ in nil }
    var enabled: () -> Bool = { false }
    var overlays: () -> [NMROverlayGroup] = { [] }
    var commit: (NMRRawBox, Bool) throws -> Void = { _,_ in throw NMRProblem("No annotation receiver installed") }
    var report: (String) -> Void = { _ in NSSound.beep() }
    private struct Drag { let map: NMRPlotMap; let a: CGPoint; var b: CGPoint }
    private var drag: Drag?
    private var ownsSequence = false

    // NSEvent.locationInWindow is in window points, not backing pixels.
    static func localPoint(_ e: NSEvent, in v: NSView) -> CGPoint { v.convert(e.locationInWindow,from:nil) }
    @discardableResult func cancel(in v: NSView) -> Bool {
        let had = drag != nil; drag = nil; if had { v.needsDisplay = true }; return had
    }
    @discardableResult func mouseDown(_ e: NSEvent, in v: NSView) -> Bool {
        drag = nil; ownsSequence = false
        guard e.type == .leftMouseDown, enabled(), let m = mapping(v) else { return false }
        let p = Self.localPoint(e,in:v); guard m.contains(p) else { return false }
        drag = Drag(map:m,a:p,b:p); ownsSequence = true; v.needsDisplay = true; return true
    }
    @discardableResult func mouseDragged(_ e: NSEvent, in v: NSView) -> Bool {
        guard ownsSequence else { return false }
        if var d = drag {
            if enabled() && mapping(v) == d.map { d.b = d.map.clamp(Self.localPoint(e,in:v)); drag = d }
            else { drag = nil }
        }
        v.needsDisplay = true; return true
    }
    @discardableResult func mouseUp(_ e: NSEvent, in v: NSView) -> Bool {
        guard ownsSequence else { return false }
        let finished = drag
        ownsSequence = false
        drag = nil
        v.needsDisplay = true
        // Drop the preview before calling out: commit/report can re-enter
        // AppKit (including a nested modal run loop).
        guard let d = finished, enabled(), mapping(v) == d.map else { return true }
        let p = Self.localPoint(e,in:v), end = d.map.clamp(p)
        // De-bounce a click in WINDOW points, independently on both plot axes.
        let a = v.convert(d.a,to:nil), h = v.convert(CGPoint(x:end.x,y:d.a.y),to:nil), k = v.convert(CGPoint(x:d.a.x,y:end.y),to:nil)
        guard hypot(h.x-a.x,h.y-a.y) >= 2, hypot(k.x-a.x,k.y-a.y) >= 2, let box = d.map.box(start:d.a,end:p) else { return true }
        do { try commit(box,!d.map.contains(p)) } catch { report(error.localizedDescription) }
        return true
    }
    func draw(in v: NSView) {
        guard let d = drag else { return }
        guard enabled(), mapping(v) == d.map else { drag = nil; return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect:d.map.clip).addClip()
        let p = NSBezierPath(rect:NMRPlotMap.rect(d.a,d.b))
        NSColor.selectedControlColor.withAlphaComponent(0.16).setFill()
        p.fill()
        NSColor.selectedControlColor.setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}

// Optional owned view. For an existing spectrum NSView forward the same four
// calls instead, falling through to its NORMAL non-marking gesture code.
final class NMRPeakCanvas: NSView {
    let boxes = NMRPeakBoxInteraction()
    var paintSpectrum: ((NSView,NSRect) -> Void)?
    var flippedForPlot = false
    override var isFlipped: Bool { flippedForPlot }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with e: NSEvent) { if boxes.mouseDown(e,in:self) { window?.makeFirstResponder(self) } else { super.mouseDown(with:e) } }
    override func mouseDragged(with e: NSEvent) { if !boxes.mouseDragged(e,in:self) { super.mouseDragged(with:e) } }
    override func mouseUp(with e: NSEvent) { if !boxes.mouseUp(e,in:self) { super.mouseUp(with:e) } }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 && boxes.cancel(in:self) { return }; super.keyDown(with:e) }
    override func viewWillMove(toWindow newWindow: NSWindow?) { boxes.cancel(in:self); super.viewWillMove(toWindow:newWindow) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect); NSGraphicsContext.saveGraphicsState(); paintSpectrum?(self,dirtyRect); NSGraphicsContext.restoreGraphicsState(); boxes.draw(in:self)
    }
}

struct NMRPeakCanvasBridge: NSViewRepresentable {
    let configure: (NMRPeakCanvas) -> Void
    func makeNSView(context: Context) -> NMRPeakCanvas { let v = NMRPeakCanvas(frame:.zero); configure(v); return v }
    func updateNSView(_ v: NMRPeakCanvas, context: Context) { configure(v); v.needsDisplay = true }
}
