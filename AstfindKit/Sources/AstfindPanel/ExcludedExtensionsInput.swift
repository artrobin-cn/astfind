import AppKit
import SwiftUI

final class ExcludedExtensionsField: NSTextField, NSTextFieldDelegate {
    let model: SettingsModel
    let editor = NSTextView()
    init(model: SettingsModel) {
        self.model = model
        super.init(frame: .zero)
        editor.isFieldEditor = true; editor.allowsUndo = true
        font = .systemFont(ofSize: 13)
        isBordered = false; drawsBackground = false; focusRingType = .none
        cell?.isScrollable = true; cell?.usesSingleLineMode = true
        stringValue = model.excludedExtensionsText
        placeholderString = L10n.text("settings.excludedTypesPlaceholder")
        setAccessibilityIdentifier("settings.excludedTypes")
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidChange(_ notification: Notification) { model.excludedExtensionsText = stringValue }
    func controlTextDidEndEditing(_ notification: Notification) { commit() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard command == #selector(NSResponder.insertNewline(_:)) else { return false }
        commit(); return true
    }
    func commit() {
        model.excludedExtensionsText = stringValue
        model.commitExcludedExtensions()
        let normalized = model.excludedExtensionsText
        if let editor = currentEditor() as? NSTextView, editor.string != normalized {
            // Keep normalization in the field editor's native undo history.
            editor.breakUndoCoalescing()
            editor.insertText(normalized, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.breakUndoCoalescing()
        }
        stringValue = normalized
    }
}

struct ExcludedExtensionsInput: NSViewRepresentable {
    @ObservedObject var model: SettingsModel
    func makeNSView(context: Context) -> ExcludedExtensionsField { ExcludedExtensionsField(model: model) }
    func updateNSView(_ field: ExcludedExtensionsField, context: Context) {
        field.placeholderString = L10n.text("settings.excludedTypesPlaceholder")
        if field.currentEditor() == nil { field.stringValue = model.excludedExtensionsText }
    }
}
