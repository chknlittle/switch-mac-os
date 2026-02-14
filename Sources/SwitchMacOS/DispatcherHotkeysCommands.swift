import AppKit
import SwiftUI
import SwitchCore

// MARK: - Menu

@MainActor
struct DispatcherHotkeysCommands: Commands {
    @ObservedObject var model: SwitchAppModel

    var body: some Commands {
        CommandMenu("Dispatchers") {
            ForEach(Array((model.directory?.dispatchers ?? []).prefix(4).enumerated()), id: \.offset) { idx, item in
                Button("Select \(idx + 1): \(item.name)  \u{2318}\(idx + 1)") {
                    model.directory?.selectDispatcher(item)
                }
            }

            Divider()

            Button("Focus Oldest Waiting Session  \u{21e7}\u{2318}\u{2191}") {
                _ = model.directory?.focusOldestWaitingSession()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
        }
    }
}

// MARK: - Key-code based event monitor (layout-agnostic)

@MainActor
final class DispatcherHotkeyMonitor {
    // Physical key codes for the number row 1-4 (same on QWERTY, Dvorak, Programmer Dvorak, etc.)
    private static let slotKeyCode: [UInt16: Int] = [
        18: 1, // 1
        19: 2, // 2
        20: 3, // 3
        21: 4, // 4
    ]

    private var monitor: Any?
    private weak var model: SwitchAppModel?

    init(model: SwitchAppModel) {
        self.model = model
    }

    // Key codes for arrow keys.
    private static let upArrowKeyCode: UInt16 = 126
    private static let downArrowKeyCode: UInt16 = 125

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let interesting: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let held = event.modifierFlags.intersection(interesting)

            // Cmd+1..4: select dispatcher.
            if held == .command, let slot = Self.slotKeyCode[event.keyCode] {
                return self.handleSlot(slot) ? nil : event
            }

            // Shift+Up/Down: navigate sessions (skip when text field has content).
            if held == .shift, !Self.isEditingText {
                if event.keyCode == Self.upArrowKeyCode {
                    return self.handleSessionNav(direction: .up) ? nil : event
                }
                if event.keyCode == Self.downArrowKeyCode {
                    return self.handleSessionNav(direction: .down) ? nil : event
                }
            }

            // Cmd+Shift+Up: jump to the session waiting longest.
            if held == [.command, .shift], !Self.isEditingText {
                if event.keyCode == Self.upArrowKeyCode {
                    return self.handleOldestWaitingSession() ? nil : event
                }
            }

            return event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Select the Nth dispatcher in display order (Cmd+1 = first, etc.)
    private func handleSlot(_ slot: Int) -> Bool {
        guard let directory = model?.directory else {
            NSSound.beep()
            return true
        }

        let index = slot - 1
        guard index >= 0, index < directory.dispatchers.count else {
            NSSound.beep()
            return true
        }

        directory.selectDispatcher(directory.dispatchers[index])
        return true
    }

    /// Only defer to the text field when it actually has text (so Shift+Arrow
    /// does text selection). Empty input → navigate sessions instead.
    private static var isEditingText: Bool {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return !tv.string.isEmpty
    }

    private enum Direction { case up, down }

    /// Navigate sessions with Shift+Up/Down.
    private func handleSessionNav(direction: Direction) -> Bool {
        guard let directory = model?.directory else { return false }
        switch direction {
        case .up:
            directory.selectPreviousSession()
        case .down:
            directory.selectNextSession()
        }
        return true
    }

    private func handleOldestWaitingSession() -> Bool {
        guard let directory = model?.directory else {
            NSSound.beep()
            return true
        }

        if directory.focusOldestWaitingSession() {
            return true
        }

        NSSound.beep()
        return true
    }
}
