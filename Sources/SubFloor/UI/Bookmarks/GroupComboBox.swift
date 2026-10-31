import AppKit
import SwiftUI

/// The bookmark group: a combo box listing the groups in use, which also takes a new name typed in.
/// Typing completes from the list. Empty means ungrouped.
struct GroupComboBox: NSViewRepresentable {
    @Binding var text: String
    let groups: [String]
    var placeholder = "None"

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.completes = true
        box.usesDataSource = false
        box.isEditable = true
        box.numberOfVisibleItems = 12
        box.placeholderString = placeholder
        box.delegate = context.coordinator
        box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.text = $text
        if box.objectValues as? [String] != groups {
            box.removeAllItems()
            box.addItems(withObjectValues: groups)
        }
        if box.stringValue != text && box.currentEditor() == nil { box.stringValue = text }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let box = note.object as? NSComboBox else { return }
            text.wrappedValue = box.stringValue
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let box = note.object as? NSComboBox else { return }
            text.wrappedValue = box.stringValue
        }

        /// Picking from the list: the selection is not in `stringValue` until after this returns.
        func comboBoxSelectionDidChange(_ note: Notification) {
            guard let box = note.object as? NSComboBox, box.indexOfSelectedItem >= 0,
                  let picked = box.itemObjectValue(at: box.indexOfSelectedItem) as? String else { return }
            text.wrappedValue = picked
        }
    }
}
