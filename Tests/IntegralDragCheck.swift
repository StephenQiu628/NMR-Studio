import AppKit

@MainActor
enum IntegralDragCheck {
    private static func settle(_ w: Workbench) throws {
        let deadline = Date().addingTimeInterval(15)
        while w.busy && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        try Check.require(!w.busy && w.error == nil, "integral drag host operation: \(w.error ?? "timeout")")
    }

    static func run() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("signed.csv")
        let rows = (0...200).map { i -> String in
            let ppm = Double(i) / 20
            return "\(ppm),\(-1 - ppm / 10)"
        }
        try ("ppm,intensity\n" + rows.joined(separator: "\n") + "\n")
            .write(to: input, atomically: true, encoding: .utf8)
        let w = Workbench()
        w.load(input)
        try settle(w)
        var settings = w.applied
        settings.offset = 1.25
        w.apply(settings)
        try settle(w)
        w.select(.integral, region: 4.25...7.25)
        let anchor = w.marks.last!.id
        w.editIntegral(w.marks.last!, bounds: 4.25...7.25, target: 3)
        w.select(.integral, region: 8.25...9.25)
        let other = w.marks.last!.id
        var analysis = w.analysis
        analysis.displayGain = 4
        w.applyAnalysis(analysis)
        try Check.require(w.reference?.markID == anchor && w.reference?.target == 3,
                          "signed reference fixture")
        let signal = w.spectrum.real
        let processing = w.applied

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let view = PlotView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        var selections: [Tool] = []
        func wire(_ tool: Tool = .zoom) {
            w.tool = tool
            let version = w.annotationVersion
            view.tool = tool
            view.onIntegralSelection = { w.pickAnnotation($0, at: version) }
            view.integralEditing = { w.beginIntegralEdit($0, at: version) }
            view.select = { action, _ in selections.append(action) }
            view.update(w.plot)
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                              timestamp: 0, windowNumber: window.windowNumber, context: nil,
                              eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func down(_ point: CGPoint) { view.mouseDown(with: event(.leftMouseDown, point)) }
        func drag(_ point: CGPoint) { view.mouseDragged(with: event(.leftMouseDragged, point)) }
        func up(_ point: CGPoint) { view.mouseUp(with: event(.leftMouseUp, point)) }
        func layout() -> PlotAnnotationLayout {
            let state = view.displayedState!
            return PlotAnnotationLayout(state, geometry: PlotGeometry(field: view.field, ordinate: state.ordinateSpan),
                                        size: view.bounds.size)
        }
        func bracket(_ id: UUID) -> PlotAnnotationLayout.Integral {
            layout().integrals.first { $0.id == id }!
        }
        func band(_ id: UUID, in plot: PlotState) -> ClosedRange<Double> {
            plot.bands[plot.bandIDs.firstIndex(of: id)!]
        }
        func hostBand(_ id: UUID) -> ClosedRange<Double> {
            w.bounds(w.marks.first { $0.id == id }!)
        }
        func cap(_ id: UUID, upper: Bool) -> CGPoint {
            let b = bracket(id)
            return CGPoint(x: upper ? b.left : b.right, y: b.y + 2)
        }

        wire()
        let original = hostBand(anchor)
        var count = w.journal.history.count
        var p = cap(anchor, upper: true)
        p.x += 5 // Inside the tolerance, not on the stroke.
        down(p); up(p)
        try Check.require(w.selectedIntegralID == anchor && w.journal.history.count == count,
                          "cap click selects without an edit")
        wire()
        p = cap(anchor, upper: true)
        p.x += 5
        down(p)
        drag(CGPoint(x: p.x - 32, y: p.y))
        let trial = view.displayedState!
        let changed = band(anchor, in: trial)
        try Check.require(changed.lowerBound == original.lowerBound &&
                          abs(changed.upperBound - original.upperBound - 0.5) < 1e-10,
                          "left cap changes upper ppm and retains local click offset")
        try Check.require(hostBand(anchor) == original && w.journal.history.count == count,
                          "preview does not mutate marks or history")
        for id in [anchor, other] {
            let area = w.spectrum.area(band(id, in: trial))
            let relative = SessionJournal.relativeArea(area, referenceArea: w.spectrum.area(changed), target: 3)!
            let index = trial.bandIDs.firstIndex(of: id)!
            try Check.require(trial.bandLabels[index] == String(format: "%.3g", relative),
                              "all signed relative labels use the trial anchor, without display gain")
        }
        try Check.require(trial.gain == 4 && trial.spectrum.real == view.state!.spectrum.real,
                          "resize does not alter the displayed signal")
        // Mouse-up must use the last displayed trial, not an unseen extra motion.
        up(CGPoint(x: p.x - 45, y: p.y))
        try Check.require(hostBand(anchor) == changed && w.journal.history.count == count + 1 &&
                          w.reference?.markID == anchor && w.reference?.target == 3 && w.selectedIntegralID == anchor,
                          "one commit of the visible preview, retaining ID, reference and selection")
        w.undo()
        try settle(w)
        try Check.require(hostBand(anchor) == original && w.reference?.target == 3,
                          "one undo restores both original boundaries and reference")

        wire(.integral)
        count = w.journal.history.count
        let otherOriginal = hostBand(other)
        p = cap(other, upper: false)
        down(p)
        drag(CGPoint(x: p.x - 10000, y: p.y))
        var resized = band(other, in: view.displayedState!)
        try Check.require(resized.lowerBound < resized.upperBound && resized.upperBound == otherOriginal.upperBound,
                          "right cap cannot cross or become a point mark")
        drag(p)
        try Check.require(band(other, in: view.displayedState!) == otherOriginal,
                          "can resize back after crossing clamp")
        up(p)
        try Check.require(w.journal.history.count == count, "out-and-back is a no-op")
        wire(.integral)
        p = cap(other, upper: false)
        down(p)
        drag(CGPoint(x: p.x + 10000, y: p.y))
        resized = band(other, in: view.displayedState!)
        try Check.require(resized.lowerBound == w.spectrum.range.lowerBound &&
                          resized.upperBound == otherOriginal.upperBound, "right cap clamps to spectrum extent")
        up(p)
        try Check.require(hostBand(other) == resized && w.journal.history.count == count + 1 &&
                          w.reference?.markID == anchor && w.reference?.target == 3,
                          "editing a non-anchor preserves the other reference")

        w.window = 5.25...9.25
        wire()
        count = w.journal.history.count
        let cropped = bracket(anchor)
        p = CGPoint(x: cropped.right - 0.5, y: cropped.y + 2)
        try Check.require(layout().integralCap(at: p, state: view.state!) == nil,
                          "crop edge is not a true integral endpoint")
        down(p); drag(CGPoint(x: p.x - 25, y: p.y)); up(CGPoint(x: p.x - 25, y: p.y))
        try Check.require(w.journal.history.count == count && selections.isEmpty,
                          "dragging a clipped edge does not resize or start a plot gesture")
        p = cap(anchor, upper: true)
        down(p); drag(CGPoint(x: p.x - 10000, y: p.y))
        resized = band(anchor, in: view.displayedState!)
        try Check.require(resized.upperBound == w.window.upperBound && resized.lowerBound == original.lowerBound,
                          "viewport clamp retains an offscreen opposite bound")
        up(p)
        try Check.require(hostBand(anchor) == resized, "cropped resize commits the entire bracket")

        w.window = w.spectrum.range
        let tinyWidth = 2 * (w.window.upperBound - w.window.lowerBound) / Double(view.field.width)
        w.select(.integral, region: 10.25...(10.25 + tinyWidth))
        let tiny = w.marks.last!.id
        w.pickAnnotation(tiny, at: w.annotationVersion)
        wire()
        let tinyOriginal = hostBand(tiny)
        p = cap(tiny, upper: false)
        p.x += 0.25
        down(p); drag(CGPoint(x: p.x + 12, y: p.y)); up(p)
        try Check.require(hostBand(tiny).upperBound == tinyOriginal.upperBound &&
                          hostBand(tiny).lowerBound < tinyOriginal.lowerBound,
                          "overlapping hit zones choose the nearest right cap of a two-point bracket")
        wire()
        let beforeLeft = hostBand(tiny)
        p = cap(tiny, upper: true)
        p.x -= 0.25
        down(p); drag(CGPoint(x: p.x - 12, y: p.y)); up(p)
        try Check.require(hostBand(tiny).lowerBound == beforeLeft.lowerBound &&
                          hostBand(tiny).upperBound > beforeLeft.upperBound,
                          "left and right resizing remain independent")

        // Adjacent annotations have overlapping tolerance rectangles on the same row.
        let first = UUID(), second = UUID()
        var tied = PlotState(spectrum: Spectrum(ppm: [10, 0], real: [1, 1]), window: 0...10,
                             bands: [2...5, 5.03125...8], title: "", bandLabels: ["1", "2"],
                             bandIDs: [first, second], selectedBandID: first)
        let geometry = PlotGeometry(field: view.field, ordinate: tied.ordinateSpan)
        var ties = PlotAnnotationLayout(tied, geometry: geometry, size: view.bounds.size)
        let a = ties.integrals.first { $0.id == first }!
        let b = ties.integrals.first { $0.id == second }!
        let midpoint = CGPoint(x: (a.left + b.right) / 2, y: a.y + 2)
        try Check.require(a.y == b.y && ties.integralCap(at: midpoint, state: tied)?.id == first,
                          "exact endpoint ambiguity prefers selected ID")
        tied.selectedBandID = second
        ties = PlotAnnotationLayout(tied, geometry: geometry, size: view.bounds.size)
        try Check.require(ties.integralCap(at: midpoint, state: tied)?.id == second &&
                          ties.integralCap(at: CGPoint(x: a.left, y: a.y + 2), state: tied)?.id == first,
                          "selection only breaks exact ties, never overrides the nearer cap")

        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        let cancellations: [() -> Void] = [
            { view.keyDown(with: escape) },
            { view.tool = .peak; view.tool = .zoom },
            { let size = view.frame.size; view.setFrameSize(CGSize(width: size.width + 1, height: size.height)); view.setFrameSize(size) },
            { window.makeFirstResponder(nil) },
            { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window) },
            { let old = w.settings; w.settings.p0 += 1; w.settings = old },
            { let old = w.window; w.window = 5...9; w.window = old },
            { let old = w.marks; let m = old[0]; w.marks[0] = Mark(id: m.id, lo: m.lo + 0.01, hi: m.hi); w.marks = old },
            { window.contentView = nil; window.contentView = view }
        ]
        for cancel in cancellations {
            wire()
            count = w.journal.history.count
            let before = hostBand(anchor)
            p = cap(anchor, upper: true)
            down(p); drag(CGPoint(x: p.x - 10, y: p.y))
            cancel()
            up(CGPoint(x: p.x - 10, y: p.y))
            try Check.require(hostBand(anchor) == before && w.journal.history.count == count && selections.isEmpty &&
                              view.displayedState!.bands == w.plot.bands,
                              "cancel/stale sequence cannot commit or turn into a zoom/integral")
        }

        wire()
        p = bracket(other).label.centerForIntegralCheck
        count = w.journal.history.count
        down(p); up(p)
        try Check.require(w.selectedIntegralID == other && w.journal.history.count == count,
                          "plain label click still selects")
        for tool in [Tool.zoom, .integral] {
            wire(tool)
            p = CGPoint(x: view.field.midX, y: view.field.midY)
            down(p); drag(CGPoint(x: p.x + 50, y: p.y)); up(CGPoint(x: p.x + 50, y: p.y))
            try Check.require(selections.last == tool, "ordinary plot gestures remain intact")
        }
        try Check.require(w.spectrum.real == signal && w.applied == processing,
                          "boundary edits preserve signal, phase and baseline settings")
        let savedRanges = w.marks.map { ($0.id, $0.lo, $0.hi) }
        let savedHistoryCount = w.journal.history.count
        let project = directory.appendingPathComponent("resized.nmrstudio")
        try w.saveProject(to: project)
        let reopened = Workbench()
        reopened.load(project)
        try settle(reopened)
        try Check.require(reopened.marks.count == savedRanges.count && savedRanges.allSatisfy { saved in
            reopened.marks.contains { $0.id == saved.0 && $0.lo == saved.1 && $0.hi == saved.2 }
        } && reopened.reference?.markID == anchor && reopened.reference?.target == 3 &&
            reopened.journal.history.count == savedHistoryCount,
                          "saved/reopened ranges, IDs, reference and history are preserved")
    }
}

private extension CGRect {
    var centerForIntegralCheck: CGPoint { CGPoint(x: midX, y: midY) }
}
