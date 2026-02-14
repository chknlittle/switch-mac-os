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

            // Shift+Up/Down: navigate sessions (skip when editing text).
            if held == .shift, !Self.isTextFieldFocused {
                if event.keyCode == Self.upArrowKeyCode {
                    return self.handleSessionNav(direction: .up) ? nil : event
                }
                if event.keyCode == Self.downArrowKeyCode {
                    return self.handleSessionNav(direction: .down) ? nil : event
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

    private static var isTextFieldFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
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
}
