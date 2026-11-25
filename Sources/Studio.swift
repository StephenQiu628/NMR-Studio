import SwiftUI
import AppKit

final class Delegate: NSObject, NSApplicationDelegate {
    weak var workbench: Workbench?
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard let w=workbench, sender.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return .terminateNow }
        return w.mayReplace() ? .terminateNow : .terminateCancel
    }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps:true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
}
@main struct NMRStudio: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    @StateObject private var w = Workbench()
    var body: some Scene {
        Window("NMR Studio",id:"spectrum") { StudioView(w:w).background(WindowMonitor(w:w)).onAppear { delegate.workbench=w } }
            .defaultSize(width:1140,height:710)
            .commands {
                CommandGroup(after:.undoRedo) {
                    Button("撤销上一步谱图操作") { w.undo() }.keyboardShortcut("z",modifiers:[.command,.option])
                        .disabled(w.busy || w.hasDraft || !w.journal.canUndo)
                    Button("操作记录…") { w.showHistory=true }
                }
                CommandGroup(replacing:.newItem) {
                    Button("打开谱图…") { w.openPanel() }.keyboardShortcut("o")
                        .disabled(w.busy)
                    Button("打开模拟氢谱") { w.requestLoad(nil) }
                        .disabled(w.busy)
                }
                CommandGroup(replacing: .saveItem) {
                    Button("保存工程") { w.save() }.keyboardShortcut("s")
                        .disabled(w.busy || w.hasDraft)
                    Button("工程另存为…") { w.save(asNew:true) }.keyboardShortcut("s", modifiers:[.shift,.command])
                        .disabled(w.busy || w.hasDraft)
                }
            }
    }
}
