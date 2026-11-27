import AppKit

// One mouse sequence. Bounds and limits use the displayed ppm axis.
struct PlotIntegralEdit {
    let bounds: ClosedRange<Double>
    let limits: ClosedRange<Double>
    let isCurrent: () -> Bool
    let preview: (ClosedRange<Double>) -> PlotState?
    let commit: (ClosedRange<Double>) -> Void
}

@MainActor
extension Workbench {
    func beginIntegralEdit(_ id: UUID, at version: StudioAnnotationVersion,
                           isCurrent: @escaping () -> Bool = { true }) -> PlotIntegralEdit? {
        guard accepts(version), isCurrent(),
              let mark = marks.first(where: { $0.id == id && !$0.isPeak }) else { return nil }
        let original = bounds(mark)
        let source = spectrum
        let epoch = integralInteractionRevision
        let delta = version.offset - applied.offset
        let displayed = (mark.lo + version.offset)...(mark.hi + version.offset)
        let limits = (source.range.lowerBound + delta)...(source.range.upperBound + delta)
        let target = reference?.markID == id ? reference?.target : nil
        guard displayed.lowerBound.isFinite, displayed.upperBound.isFinite,
              limits.lowerBound.isFinite, limits.upperBound.isFinite,
              source.range.contains(original.lowerBound), source.range.contains(original.upperBound)
        else { return nil }

        let valid: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.accepts(version) && self.integralInteractionRevision == epoch && isCurrent() &&
                self.marks.contains { $0.id == id && $0.lo == mark.lo && $0.hi == mark.hi }
        }
        let appliedRange: (ClosedRange<Double>) -> ClosedRange<Double>? = { range in
            guard range.lowerBound.isFinite, range.upperBound.isFinite,
                  range.lowerBound < range.upperBound,
                  limits.contains(range.lowerBound), limits.contains(range.upperBound) else { return nil }
            // Preserve the untouched endpoint exactly, including at nonzero offsets.
            let lo = range.lowerBound == displayed.lowerBound ? original.lowerBound :
                min(source.range.upperBound, max(source.range.lowerBound, range.lowerBound - delta))
            let hi = range.upperBound == displayed.upperBound ? original.upperBound :
                min(source.range.upperBound, max(source.range.lowerBound, range.upperBound - delta))
            guard lo.isFinite, hi.isFinite, lo < hi else { return nil }
            let result = lo...hi
            if let target {
                let area = source.area(result)
                guard SessionJournal.relativeArea(area, referenceArea: area, target: target) != nil else {
                    return nil
                }
            }
            return result
        }
        return PlotIntegralEdit(bounds: displayed, limits: limits, isCurrent: valid, preview: { [weak self] range in
            guard let self, valid(), let trial = appliedRange(range) else { return nil }
            return self.annotationPlot(selecting: id, trial: (id, trial))
        }, commit: { [weak self] range in
            guard let self, valid(), let next = appliedRange(range) else { return }
            if next != original { self.editIntegral(mark, bounds: next, target: target) }
            self.pickAnnotation(id, at: self.annotationVersion)
        })
    }
}
