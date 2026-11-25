import AppKit

// All rectangles are in unflipped view points, including for the PDF context.
struct PlotRegions {
    let header: CGRect
    let peakStrip: CGRect
    let gutter: CGRect
    let axisY: CGFloat

    init(size: CGSize, field r: CGRect) {
        let h = max(0, size.height)
        let headerHeight = min(23, max(0, h - r.maxY))
        header = CGRect(x: r.minX, y: h - headerHeight, width: r.width, height: headerHeight)
        let peakBottom = r.maxY + 1
        peakStrip = CGRect(x: r.minX, y: peakBottom, width: r.width,
                           height: max(0, header.minY - 2 - peakBottom))
        axisY = min(41, floor(r.minY * 0.55))
        let bottom = axisY + 6
        gutter = CGRect(x: r.minX, y: bottom, width: r.width,
                        height: max(0, r.minY - 3 - bottom))
    }
}

@MainActor
enum PlotInk {
    static func font(_ size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    static func measure(_ text: String, _ font: NSFont) -> CGSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }

    static func draw(_ text: String, at p: CGPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }

    static func line(_ a: CGPoint, _ b: CGPoint, _ color: NSColor, _ width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    // Bound work on arbitrary host strings. Preserve composed characters,
    // localized decimal separators, signs and nonbreaking spaces.
    static func singleLine(_ source: String) -> String {
        let part = source.prefix(192)
        let text = String(part).components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return part.endIndex == source.endIndex ? text : text + "…"
    }

    static func fitted(_ text: String, font: NSFont, width: CGFloat) -> String {
        guard width > 0 else { return "" }
        if measure(text, font).width <= width { return text }
        let ellipsis = "…"
        guard measure(ellipsis, font).width <= width else { return "" }
        let chars = Array(text)
        var low = 0, high = chars.count
        while low < high {
            let mid = low + (high - low + 1) / 2
            if measure(String(chars.prefix(mid)) + ellipsis, font).width <= width {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return String(chars.prefix(low)) + ellipsis
    }

    static func shift(_ value: Double, digits: Int) -> String {
        if abs(value) >= 1e8 {
            return String(format: "%.7g", locale: Locale.current, value)
        }
        let zero = 0.5 * pow(10.0, -Double(digits))
        return String(format: "%.*f", locale: Locale.current, digits, abs(value) < zero ? 0.0 : value)
    }

    // Local to plot annotations; does not change the palette of other controls.
    static func integralGreen(dark: Bool, contrast: Bool) -> NSColor {
        if dark {
            return contrast
                ? NSColor(srgbRed: 0.72, green: 1, blue: 0.78, alpha: 1)
                : NSColor(srgbRed: 0.51, green: 0.88, blue: 0.61, alpha: 1)
        }
        return contrast
            ? NSColor(srgbRed: 0.02, green: 0.30, blue: 0.13, alpha: 1)
            : NSColor(srgbRed: 0.06, green: 0.39, blue: 0.19, alpha: 1)
    }
}

@MainActor
struct PlotAnnotationLayout {
    struct Peak {
        let ppm: Double
        let copies: Int
        let x: CGFloat
        let tip: CGFloat
        let direction: CGFloat
        let text: String
        let size: CGSize
    }

    struct PeakLabel {
        let index: Int
        let frame: CGRect
        let rotated: Bool
    }

    struct Integral {
        let index: Int             // original index, NOT an index in a sorted/filtered array
        let id: UUID?
        let left: CGFloat
        let right: CGFloat
        let y: CGFloat             // horizontal stroke; the two caps point towards the trace
        let label: CGRect
        let text: String
        let fullText: String

        var valueHit: CGRect { label.insetBy(dx: -2, dy: -1.5) }
        var bracketHit: CGRect {
            CGRect(x: left - 2.5, y: y - 2, width: right - left + 5, height: 8)
        }
    }

    let regions: PlotRegions
    let peaks: [Peak]
    let labels: [PeakLabel]
    let integrals: [Integral]
    let omittedPeaks: Int
    let omittedIntegrals: Int

    private static let peakFont = PlotInk.font(11)
    private static let bandFont = PlotInk.font(11)
    private static let gap: CGFloat = 3

    init(_ state: PlotState, geometry: PlotGeometry, size: CGSize) {
        let r = PlotRegions(size: size, field: geometry.field)
        regions = r

        let (marks, totalPeaks) = Self.makePeaks(state, geometry)
        let placed = Self.placePeaks(marks, in: r.peakStrip, selected: state.selectedPeak)
        peaks = marks
        labels = placed
        omittedPeaks = totalPeaks - placed.reduce(0) { $0 + marks[$1.index].copies }

        let (brackets, totalBands) = Self.makeIntegrals(state, geometry, gutter: r.gutter)
        integrals = brackets
        omittedIntegrals = totalBands - brackets.count
    }

    var omissionNote: String {
        var parts: [String] = []
        if omittedPeaks > 0 { parts.append("峰 \(omittedPeaks)") }
        if omittedIntegrals > 0 { parts.append("积分 \(omittedIntegrals)") }
        return parts.isEmpty ? "" : "未标出：" + parts.joined(separator: " · ")
    }

    // Unsorted host arrays can be arbitrarily large. Filter against the crop
    // BEFORE limiting. On overflow allocate samples across occupied x bins,
    // then thin evenly within each bin. Only bounded arrays get sorted,
    // measured, mapped to trace samples or turned into drawing primitives.
    private static func sample(_ count: Int, limit: Int,
                               fraction: (Int) -> Double?,
                               preferred: (Int) -> Bool) -> (indices: [Int], total: Int) {
        let bins = 32
        func bin(_ t: Double) -> Int {
            min(bins - 1, Int(min(1, max(0, t)) * Double(bins)))
        }
        var totals = [Int](repeating: 0, count: bins)
        var result: [Int] = []
        result.reserveCapacity(min(count, limit))
        var special: (index: Int, bin: Int)?
        var total = 0
        for i in 0..<count {
            guard let t = fraction(i), t.isFinite else { continue }
            let b = bin(t)
            totals[b] += 1
            total += 1
            if result.count < limit { result.append(i) }
            if special == nil, preferred(i) { special = (i, b) }
        }
        guard total > limit else { return (result, total) }

        result.removeAll(keepingCapacity: true)
        if let special {
            result.append(special.index)
            totals[special.bin] -= 1
        }
        var quota = [Int](repeating: 0, count: bins)
        var remaining = limit - result.count
        while remaining > 0 {
            for b in 0..<bins where quota[b] < totals[b] {
                quota[b] += 1
                remaining -= 1
                if remaining == 0 { break }
            }
        }
        var seen = [Int](repeating: 0, count: bins)
        var taken = seen
        for i in 0..<count {
            if i == special?.index { continue }
            guard let t = fraction(i), t.isFinite else { continue }
            let b = bin(t), q = quota[b]
            guard taken[b] < q else { continue }
            let rank = q == 1 ? (totals[b] - 1) / 2 :
                Int((Double(totals[b] - 1) * Double(taken[b]) / Double(q - 1)).rounded())
            if seen[b] == rank {
                result.append(i)
                taken[b] += 1
            }
            seen[b] += 1
        }
        return (result, total)
    }

    private static func makePeaks(_ s: PlotState, _ g: PlotGeometry) -> ([Peak], Int) {
        let w = s.window, span = w.upperBound - w.lowerBound
        let pick = sample(s.peaks.count, limit: 1024, fraction: { i in
            let v = s.peaks[i]
            guard v.isFinite, w.contains(v) else { return nil }
            return (w.upperBound - v) / span
        }, preferred: { s.peaks[$0] == s.selectedPeak })
        let sorted = pick.indices.map { s.peaks[$0] }.sorted(by: >)
        var groups: [(ppm: Double, copies: Int)] = []
        for v in sorted {
            if let j = groups.indices.last, groups[j].ppm == v { groups[j].copies += 1 }
            else { groups.append((v, 1)) }
        }

        var marks: [Peak] = []
        for i in groups.indices {
            let (v, copies) = groups[i]
            let prev = i == 0 ? Double.infinity : groups[i - 1].ppm - v
            let next = i + 1 == groups.count ? Double.infinity : v - groups[i + 1].ppm
            let d = min(prev, next)
            let digits = d > 0 && d < 0.001 ? min(7, max(3, Int(ceil(-log10(d))))) : 3
            let text = PlotInk.shift(v, digits: digits) + (copies > 1 ? " ×\(copies)" : "")
            let value = s.spectrum.real[s.spectrum.nearest(v)]
            marks.append(Peak(ppm: v, copies: copies, x: g.x(v, in: w), tip: g.y(value),
                              direction: value < 0 ? -1 : 1, text: text,
                              size: PlotInk.measure(text, peakFont)))
        }
        return (marks, pick.total)
    }

    // Least-squares ordered placement on one row. Subtract the cumulative
    // label widths/gaps; non-overlap then becomes a monotone-offset constraint.
    // Pool adjacent violators, and clamp the offsets to the available slack.
    // This spreads a tied cluster *around* its anchors, including at the edges.
    private struct Pool {
        let first: Int
        let end: Int
        let sum: CGFloat
        var mean: CGFloat { sum / CGFloat(end - first) }
    }

    private static func lefts(centers: [CGFloat], widths: [CGFloat],
                              in r: CGRect, gap: CGFloat) -> [CGFloat] {
        guard !centers.isEmpty else { return [] }
        var cursor = r.minX
        var starts: [CGFloat] = [], pools: [Pool] = []
        for i in centers.indices {
            starts.append(cursor)
            var p = Pool(first: i, end: i + 1, sum: centers[i] - widths[i] / 2 - cursor)
            while let last = pools.last, last.mean > p.mean {
                pools.removeLast()
                p = Pool(first: last.first, end: p.end, sum: last.sum + p.sum)
            }
            pools.append(p)
            cursor += widths[i] + gap
        }
        let slack = max(0, r.maxX - (cursor - gap))
        for p in pools {
            let offset = min(slack, max(0, p.mean))
            for i in p.first..<p.end { starts[i] += offset }
        }
        return starts
    }

    // When even multiple rows cannot fit everything, don't just label the
    // leftmost prefix. Use endpoints then successively bisect sorted ranks.
    private static func spreadOrder(_ n: Int, preferred: Int?) -> [Int] {
        guard n > 0 else { return [] }
        var order: [Int] = [], used = [Bool](repeating: false, count: n)
        func add(_ i: Int) {
            if !used[i] { used[i] = true; order.append(i) }
        }
        if let preferred { add(preferred) }
        add(0); add(n - 1)
        var queue = [(0, n - 1)]
        var cursor = 0
        while cursor < queue.count {
            let (a, b) = queue[cursor]
            cursor += 1
            if b - a < 2 { continue }
            let m = (a + b) / 2
            add(m)
            if m - a > 1 { queue.append((a, m)) }
            if b - m > 1 { queue.append((m, b)) }
        }
        return order
    }

    private static func fanHeight(_ r: CGRect) -> CGFloat {
        min(13, max(4, floor(r.height * 0.21)))
    }

    private static func placePeaks(_ marks: [Peak], in r: CGRect, selected: Double?) -> [PeakLabel] {
        guard !marks.isEmpty, r.width > 0 else { return [] }
        let bottom = r.minY + fanHeight(r), room = r.maxY - bottom
        guard room > 0 else { return [] }
        let special = marks.firstIndex { $0.ppm == selected }
        let spread = spreadOrder(marks.count, preferred: special)
        var best: [PeakLabel] = [], bestCost = CGFloat.infinity, bestSelected = false

        for rotated in [false, true] {
            let widths = marks.map { rotated ? $0.size.height : $0.size.width }
            let heights = marks.map { rotated ? $0.size.width : $0.size.height }
            let fits = marks.indices.filter { widths[$0] <= r.width && heights[$0] <= room }
            guard let rowH = fits.map({ heights[$0] }).max(), rowH > 0 else { continue }
            let rows = min(8, min(fits.count, Int(floor((room + 2) / (rowH + 2)))))
            guard rows > 0 else { continue }
            let totalW = fits.reduce(CGFloat.zero) { $0 + widths[$1] }

            for n in 1...rows {
                let pressure = totalW + CGFloat(max(0, fits.count - n)) * gap >= CGFloat(n) * r.width * 0.98
                let order = pressure ? spread : fits
                var lanes = [[Int]](repeating: [], count: n)
                var loads = [CGFloat](repeating: 0, count: n)
                for i in order where widths[i] <= r.width && heights[i] <= room {
                    var choice: Int?
                    for j in 0..<n {
                        let load = loads[j] + widths[i] + (lanes[j].isEmpty ? 0 : gap)
                        if load <= r.width, choice.map({ loads[j] < loads[$0] }) ?? true {
                            choice = j
                        }
                    }
                    if let j = choice {
                        loads[j] += widths[i] + (lanes[j].isEmpty ? 0 : gap)
                        lanes[j].append(i)
                    }
                }

                var result: [PeakLabel] = []
                var drift: CGFloat = 0, maxDrift: CGFloat = 0
                var used = 0, includesSelected = false
                for j in lanes.indices where !lanes[j].isEmpty {
                    used += 1
                    let ids = lanes[j].sorted() // ppm descending; stable even at indistinguishable x
                    let starts = lefts(centers: ids.map { marks[$0].x }, widths: ids.map { widths[$0] },
                                       in: r, gap: gap)
                    for (k, i) in ids.enumerated() {
                        let frame = CGRect(x: starts[k], y: bottom + CGFloat(j) * (rowH + 2),
                                           width: widths[i], height: heights[i])
                        let dx = abs(frame.midX - marks[i].x)
                        drift += dx
                        maxDrift = max(maxDrift, dx)
                        includesSelected = includesSelected || i == special
                        result.append(PeakLabel(index: i, frame: frame, rotated: rotated))
                    }
                }
                guard !result.isEmpty else { continue }
                // First maximize the labelled count. Among equivalent plans
                // prefer short leaders, then avoid unnecessary rows/rotation.
                let cost = drift / CGFloat(result.count) + 0.30 * maxDrift +
                    5.5 * CGFloat(used - 1) + (rotated ? 8 : 0)
                if result.count > best.count ||
                    (result.count == best.count && ((includesSelected && !bestSelected) ||
                      (includesSelected == bestSelected && cost < bestCost))) {
                    best = result
                    bestCost = cost
                    bestSelected = includesSelected
                }
            }
        }
        return best.sorted { $0.index < $1.index }
    }

    private struct BandSeed {
        let index: Int
        let left: CGFloat
        let right: CGFloat
        let text: String
        let fullText: String
        let size: CGSize
        var center: CGFloat { (left + right) / 2 }
    }

    private static func makeIntegrals(_ s: PlotState, _ g: PlotGeometry, gutter r: CGRect) -> ([Integral], Int) {
        let w = s.window, span = w.upperBound - w.lowerBound
        let pick = sample(s.bands.count, limit: 512, fraction: { i in
            let b = s.bands[i]
            guard b.lowerBound.isFinite, b.upperBound.isFinite, b.overlaps(w) else { return nil }
            let a = (w.upperBound - min(w.upperBound, b.upperBound)) / span
            let z = (w.upperBound - max(w.lowerBound, b.lowerBound)) / span
            return (a + z) / 2
        }, preferred: { s.bands[$0] == s.selectedBand })
        guard !pick.indices.isEmpty, r.height >= PlotInk.measure("0", bandFont).height + 10
        else { return ([], pick.total) }

        var seeds: [BandSeed] = []
        var measured: [ClosedRange<Double>: String] = [:]
        for i in pick.indices {
            let b = s.bands[i]
            let left = g.x(min(w.upperBound, b.upperBound), in: w)
            let right = g.x(max(w.lowerBound, b.lowerBound), in: w)
            var full = s.bandLabels.indices.contains(i) ? PlotInk.singleLine(s.bandLabels[i]) : ""
            if full.isEmpty {
                if let saved = measured[b] {
                    full = saved
                } else {
                    // Use the WHOLE measurement, not the fragment visible in
                    // this crop. Gain has the same meaning as in the raw box map.
                    let a = s.gain.isFinite && s.gain != 0 ? s.spectrum.area(b) / s.gain : Double.nan
                    full = a.isFinite ? String(format: "%.5g", locale: Locale.current, a == 0 ? 0.0 : a) : "—"
                    measured[b] = full
                }
            }
            let text = PlotInk.fitted(full, font: bandFont, width: r.width)
            let size = PlotInk.measure(text, bandFont)
            if !text.isEmpty && size.height + 10 <= r.height {
                seeds.append(BandSeed(index: i, left: left, right: right, text: text, fullText: full, size: size))
            }
        }
        // Earliest finish first. On each row the brackets themselves are
        // immutable intervals; only the value labels are allowed to slide.
        seeds.sort {
            if $0.right != $1.right { return $0.right < $1.right }
            if $0.left != $1.left { return $0.left < $1.left }
            return $0.index < $1.index
        }
        guard let labelHeight = seeds.map({ $0.size.height }).max() else { return ([], pick.total) }
        let stride = labelHeight + 10
        let rows = min(8, Int(floor(r.height / stride)))
        guard rows > 0 else { return ([], pick.total) }

        func distribute(reserving special: Int?) -> [[Int]] {
            var lanes = [[Int]](repeating: [], count: rows)
            var loads = [CGFloat](repeating: 0, count: rows)
            var lastEdge = [CGFloat](repeating: -.infinity, count: rows)
            var textEdge = lastEdge
            if let i = special {
                lanes[0].append(i)
                loads[0] = seeds[i].size.width
            }
            for i in seeds.indices where i != special {
                let b = seeds[i]
                let wanted = min(r.maxX - b.size.width, max(r.minX, b.center - b.size.width / 2))
                var best: Int?, cost = CGFloat.infinity
                for j in 0..<rows {
                    if j == 0, let k = special,
                       !(b.right + 1 <= seeds[k].left || seeds[k].right + 1 <= b.left) { continue }
                    guard lastEdge[j] + 1 <= b.left,
                          loads[j] + (lanes[j].isEmpty ? 0 : gap) + b.size.width <= r.width
                    else { continue }
                    let c = max(0, textEdge[j] + gap - wanted) + CGFloat(j) * 5
                    if c < cost { cost = c; best = j }
                }
                if let j = best {
                    loads[j] += (lanes[j].isEmpty ? 0 : gap) + b.size.width
                    lanes[j].append(i)
                    lastEdge[j] = b.right
                    textEdge[j] = max(wanted, textEdge[j] + gap) + b.size.width
                }
            }
            return lanes
        }

        var lanes = distribute(reserving: nil)
        if let k = seeds.firstIndex(where: { s.bands[$0.index] == s.selectedBand }),
           !lanes.contains(where: { $0.contains(k) }) {
            lanes = distribute(reserving: k)
        }

        var result: [Integral] = []
        for j in lanes.indices {
            let ids = lanes[j].sorted() // disjoint brackets on this row
            let starts = lefts(centers: ids.map { seeds[$0].center }, widths: ids.map { seeds[$0].size.width },
                               in: r, gap: gap)
            let y = r.maxY - CGFloat(j) * stride - 5
            for (k, i) in ids.enumerated() {
                let b = seeds[i]
                let label = CGRect(x: starts[k], y: y - 4 - b.size.height, width: b.size.width, height: b.size.height)
                let id = s.bandIDs.indices.contains(b.index) ? s.bandIDs[b.index] : nil
                result.append(Integral(index: b.index, id: id, left: b.left, right: b.right, y: y,
                                       label: label, text: b.text, fullText: b.fullText))
            }
        }
        return (result, pick.total)
    }

    func integralID(at p: CGPoint) -> UUID? {
        guard regions.gutter.contains(p) else { return nil }
        // Prefer actual ink/value bounds over the small pointing tolerance.
        if let b = integrals.first(where: { $0.id != nil && $0.label.contains(p) }) { return b.id }
        var best: UUID?, distance = CGFloat.infinity
        for b in integrals {
            guard let id = b.id else { continue }
            if b.valueHit.contains(p) {
                let dx = max(0, max(b.label.minX - p.x, p.x - b.label.maxX))
                let dy = max(0, max(b.label.minY - p.y, p.y - b.label.maxY))
                let d = hypot(dx, dy)
                if d < distance { distance = d; best = id }
            }
            if b.bracketHit.contains(p) {
                let x = min(b.right, max(b.left, p.x))
                let capY = max(b.y, min(b.y + 4, p.y))
                let d = min(hypot(x - p.x, b.y - p.y),
                            hypot(min(abs(b.left - p.x), abs(b.right - p.x)), capY - p.y))
                if d < distance { distance = d; best = id }
            }
        }
        return best
    }

    func drawTraceTicks(color: NSColor, selected: Double?) {
        let normal = NSBezierPath(), strong = NSBezierPath()
        for p in peaks where p.tip.isFinite {
            let active = p.ppm == selected
            let path = active ? strong : normal
            path.move(to: CGPoint(x: p.x, y: p.tip + p.direction * 1.7))
            path.line(to: CGPoint(x: p.x, y: p.tip + p.direction * (active ? 9 : 6)))
        }
        color.setStroke()
        normal.lineWidth = 1
        normal.stroke()
        strong.lineWidth = 2
        strong.stroke()
    }

    func drawPeakStrip(colors: PlotPalette) {
        guard !labels.isEmpty else { return }
        let r = regions.peakStrip, knee = r.minY + Self.fanHeight(r) - 1
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: r).addClip()
        let leaders = NSBezierPath()
        for l in labels {
            let x = peaks[l.index].x
            leaders.move(to: CGPoint(x: x, y: r.minY))
            leaders.line(to: CGPoint(x: x, y: r.minY + 2))
            leaders.line(to: CGPoint(x: l.frame.midX, y: knee))
            leaders.line(to: CGPoint(x: l.frame.midX, y: l.frame.minY))
        }
        colors.peak.withAlphaComponent(0.78).setStroke()
        leaders.lineWidth = 0.65
        leaders.stroke()

        // Knock out leaders under text on the intervening rows, not in
        // the trace. The text remains native vector text in the PDF.
        for l in labels {
            colors.background.setFill()
            l.frame.insetBy(dx: -0.6, dy: -0.4).fill()
            if l.rotated, let cg = NSGraphicsContext.current?.cgContext {
                NSGraphicsContext.saveGraphicsState()
                cg.translateBy(x: l.frame.maxX, y: l.frame.minY)
                cg.rotate(by: .pi / 2)
                PlotInk.draw(peaks[l.index].text, at: .zero, font: Self.peakFont, color: colors.peak)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                PlotInk.draw(peaks[l.index].text, at: l.frame.origin, font: Self.peakFont, color: colors.peak)
            }
        }
    }

    func drawIntegrals(state: PlotState, color: NSColor, showSelection: Bool) {
        guard !integrals.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Allow half the end-cap stroke at the crop edges.
        NSBezierPath(rect: regions.gutter.insetBy(dx: -1, dy: 0)).addClip()
        for b in integrals {
            let selected = showSelection && state.bands[b.index] == state.selectedBand
            let p = NSBezierPath()
            p.move(to: CGPoint(x: b.left, y: b.y + 4))
            p.line(to: CGPoint(x: b.left, y: b.y))
            p.line(to: CGPoint(x: b.right, y: b.y))
            p.line(to: CGPoint(x: b.right, y: b.y + 4))
            p.lineWidth = selected ? 1.9 : 1
            color.setStroke()
            p.stroke()
            let mid = (b.left + b.right) / 2
            if abs(mid - b.label.midX) > 2 {
                PlotInk.line(CGPoint(x: mid, y: b.y), CGPoint(x: b.label.midX, y: b.label.maxY + 0.5),
                             color, 0.6)
            }
            PlotInk.draw(b.text, at: b.label.origin, font: Self.bandFont, color: color)
        }
    }

    func drawHeader(_ title: String, color: NSColor) {
        let r = regions.header
        guard r.width > 0, r.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: r).addClip()
        var right = r.maxX
        if !omissionNote.isEmpty {
            let font = PlotInk.font(11)
            var note = omissionNote
            if PlotInk.measure(note, font).width > r.width * 0.72 {
                var counts: [String] = []
                if omittedPeaks > 0 { counts.append("δ+\(omittedPeaks)") }
                if omittedIntegrals > 0 { counts.append("∫+\(omittedIntegrals)") }
                note = counts.joined(separator: " ")
            }
            note = PlotInk.fitted(note, font: font, width: r.width)
            let size = PlotInk.measure(note, font)
            right -= size.width
            PlotInk.draw(note, at: CGPoint(x: right, y: r.midY - size.height / 2), font: font, color: color)
            right -= 8
        }
        let font = PlotInk.font(13)
        let text = PlotInk.fitted(title, font: font, width: right - r.minX)
        let h = PlotInk.measure(text, font).height
        PlotInk.draw(text, at: CGPoint(x: r.minX, y: r.midY - h / 2), font: font, color: color)
    }
}
