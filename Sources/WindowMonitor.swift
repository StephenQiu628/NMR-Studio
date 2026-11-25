import AppKit
import SwiftUI

// SwiftUI owns the window delegate; forward its other callbacks untouched.
struct WindowMonitor: NSViewRepresentable {
    @ObservedObject var w: Workbench
    func makeNSView(context:Context) -> WindowMonitorView { WindowMonitorView() }
    func updateNSView(_ view:WindowMonitorView, context:Context) {
        view.workbench=w
        view.window?.isDocumentEdited=w.dirty || w.hasDraft
    }
}

final class WindowMonitorView:NSView, NSWindowDelegate {
    weak var workbench:Workbench?
    private weak var original:NSWindowDelegate?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window.delegate !== self else { return }
        original=window.delegate
        window.delegate=self
    }
    override func viewWillMove(toWindow newWindow:NSWindow?) {
        if let window, window.delegate === self { window.delegate=original }
        super.viewWillMove(toWindow:newWindow)
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard original?.windowShouldClose?(sender) ?? true else { return false }
        return workbench?.mayReplace() ?? true
    }
    override func responds(to selector:Selector!) -> Bool {
        super.responds(to:selector) || original?.responds(to:selector) == true
    }
    override func forwardingTarget(for selector:Selector!) -> Any? {
        if original?.responds(to:selector) == true { return original }
        return super.forwardingTarget(for:selector)
    }
}
