import AppKit
import SwiftUI

@main
struct UISmoke {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        func value(_ name: String, _ fallback: String) -> String {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
            return args[i + 1]
        }
        let theme = value("--theme", "dark")
        let mode = NMRSimpleTool(rawValue: value("--mode", "integral")) ?? .integral
        let width = Double(value("--width", "1280")) ?? 1280
        let height = Double(value("--height", "820")) ?? 820
        let destination = URL(fileURLWithPath: value("--output", "/tmp/nmr-ui-smoke.png"))
        // Process-local argument-domain preference. Never changes the user's saved theme.
        UserDefaults.standard.setVolatileDomain(["NMRStudio.appearance": theme], forName: UserDefaults.argumentDomain)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let w = Workbench()
        let deadline = Date().addingTimeInterval(30)
        while w.busy && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        guard !w.busy, w.error == nil else { throw NMRError("UI fixture could not load") }
        for range in [3.95...4.30, 1.90...2.20, 1.10...1.42] { w.select(.integral, region: range) }
        let integral = w.marks.filter { !$0.isPeak }[1]
        w.editIntegral(integral, bounds: w.bounds(integral), target: 3)
        w.pickAnnotation(integral.id, at: w.annotationVersion)
        let before = w.marks.map { ($0.id, $0.lo, $0.hi) }
        let historyCount = w.journal.history.count
        let beforeSignal = w.spectrum.real
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
        let view = NSHostingView(rootView: StudioView(w: w, initialTool: mode))
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        let settleUntil = Date().addingTimeInterval(1)
        while Date() < settleUntil { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func plots(_ node: NSView) -> [PlotView] {
            (node as? PlotView).map { [$0] } ?? node.subviews.flatMap(plots)
        }
        let list = plots(view)
        guard list.count == 1, let plot = list.first, let state = plot.state else { throw NMRError("Expected one actual native plot") }
        let expectedBands = mode == .integral ? 3 : 0
        guard state.bands.count == expectedBands else { throw NMRError("Mode leaked or lost integral display") }
        let dark = plot.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark == (theme == "dark") else { throw NMRError("Native plot appearance disagrees with SwiftUI") }
        guard before.count == w.marks.count,
              zip(before, w.marks).allSatisfy({ $0.0.0 == $0.1.id && $0.0.1 == $0.1.lo && $0.0.2 == $0.1.hi }),
              historyCount == w.journal.history.count, beforeSignal == w.spectrum.real else {
            throw NMRError("Presentation changed project data")
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NMRError("Cannot render native UI") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NMRError("Cannot encode native UI") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: destination)
        print("PASS native UI \(theme) \(mode.rawValue) \(Int(width))×\(Int(height)); displayed integrals \(state.bands.count); project unchanged; \(destination.path)")
        window.contentView = nil
    }
}
