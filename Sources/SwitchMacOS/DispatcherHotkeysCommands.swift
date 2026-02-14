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

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Require Cmd held, no other modifiers besides Cmd (allow caps lock)
            let interesting: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            guard event.modifierFlags.intersection(interesting) == .command else { return event }
            guard let slot = Self.slotKeyCode[event.keyCode] else { return event }
            return self.handleSlot(slot) ? nil : event
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
}
