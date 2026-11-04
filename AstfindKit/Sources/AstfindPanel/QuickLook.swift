import AppKit
import Quartz

final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var selectedURL: (() -> URL?)?
    var onKey: ((NSEvent) -> Bool)?
    /// M0.6：QuickLook 可见期间产生前台活动信号；关闭后由引擎按宽限退出。
    var onVisibilityChanged: ((Bool) -> Void)?
    private var activityVisible = false
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }
    func toggle() {
        if isVisible { close() }
        else if selectedURL?() != nil { QLPreviewPanel.shared().makeKeyAndOrderFront(nil) }
    }
    func close() {
        if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().orderOut(nil) }
        setActivity(false)
    }
    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self; panel.delegate = self
        setActivity(true)
    }
    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil; panel.delegate = nil
        setActivity(false)
    }
    func windowWillClose(_ notification: Notification) { setActivity(false) }
    private func setActivity(_ visible: Bool) {
        guard activityVisible != visible else { return }
        activityVisible = visible
        onVisibilityChanged?(visible)
    }
    func refresh() { if isVisible { QLPreviewPanel.shared().reloadData() } }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURL?() == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { selectedURL?() as NSURL? }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 49 { return onKey?(event) ?? false }
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "y") {
            close(); return true
        }
        if [125, 126, 116, 121, 115, 119].contains(event.keyCode) {
            let handled = onKey?(event) ?? false; refresh(); return handled
        }
        return false
    }
}
