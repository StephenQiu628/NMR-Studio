import SwiftUI

struct OperationHistoryView: View {
    @ObservedObject var w:Workbench
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("操作记录").font(.headline); Spacer(); Button("完成"){dismiss()}.keyboardShortcut(.cancelAction) }
            if w.journal.history.isEmpty { Text("当前工程尚无操作记录。").foregroundStyle(.secondary) }
            List(w.journal.history.reversed()) { event in
                VStack(alignment:.leading,spacing:3) {
                    Text(event.text).textSelection(.enabled)
                    Text(event.date.formatted(date:.numeric,time:.standard)).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical,3)
            }
            Button("撤销上一步") { w.undo() }.disabled(!w.journal.canUndo || w.hasDraft || w.busy)
        }.padding(16).frame(minWidth:430,minHeight:290)
    }
}
