import AppKit
import Combine

final class RecordingEditorWindow: NSWindow {
    enum EditCommand { case split, delete, undo, redo }
    let editCommands = PassthroughSubject<EditCommand, Never>()

    private func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !(firstResponder is NSTextView) else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let command: EditCommand
        switch (modifiers, key) {
        case (.command, "b"): command = .split
        case (.command, "z"): command = .undo
        case ([.command, .shift], "z"): command = .redo
        case ([], _) where event.keyCode == 51 || event.keyCode == 117: command = .delete
        default: return false
        }
        if !event.isARepeat { editCommands.send(command) }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(event) || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if !handle(event) { super.sendEvent(event) }
    }
}
