import AppKit
import SwiftUI
import SwitchCore

// MARK: - Menu

@MainActor
struct DispatcherHotkeysCommands: Commands {
    @ObservedObject var model: SwitchAppModel

    private var defaultOCDispatcher: DirectoryItem? {
        let dispatchers = model.directory?.dispatchers ?? []
        return DispatcherHotkeyMonitor.defaultOCDispatcher(in: dispatchers)
    }

    var body: some Commands {
        CommandMenu("Dispatchers") {
            ForEach(Array((model.directory?.dispatchers ?? []).prefix(4).enumerated()), id: \.offset) { idx, item in
                Button("Select \(idx + 1): \(item.name)  \u{2318}\(idx + 1)") {
                    model.directory?.selectDispatcher(item)
                }
            }

            if let oc = defaultOCDispatcher {
                Button("Select 5: \(oc.name)  \u{2318}5") {
                    model.directory?.selectDispatcher(oc)
                }
            }

            Divider()

            Button("Focus Oldest Waiting Session  \u{21e7}\u{2318}\u{2191}") {
                _ = model.directory?.focusOldestWaitingSession()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .shift])

            Button("Focus Oldest Waiting Session (Alt)  \u{21e7}\u{2318}L") {
                _ = model.directory?.focusOldestWaitingSession()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Key-code based event monitor (layout-agnostic)

@MainActor
final class DispatcherHotkeyMonitor {
    // Physical key codes for the number row 1-6 (same on QWERTY, Dvorak, Programmer Dvorak, etc.)
    private static let slotKeyCode: [UInt16: Int] = [
        18: 1, // 1
        19: 2, // 2
        20: 3, // 3
        21: 4, // 4
        23: 5, // 5
        22: 6, // 6
    ]

    private var monitor: Any?
    private weak var model: SwitchAppModel?

    init(model: SwitchAppModel) {
        self.model = model
    }

    // Key codes for arrow keys.
    private static let upArrowKeyCode: UInt16 = 126
    private static let downArrowKeyCode: UInt16 = 125
    private static let lKeyCode: UInt16 = 37
    private static let tabKeyCode: UInt16 = 48

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let interesting: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let held = event.modifierFlags.intersection(interesting)

            // Cmd+1..6: select dispatcher (5 targets default oc@ dispatcher).
            if held == .command, let slot = Self.slotKeyCode[event.keyCode] {
                return self.handleSlot(slot) ? nil : event
            }

            // Shift+Up/Down: navigate sessions (skip when text field has content).
            if held == .shift, !Self.isEditingText {
                switch event.keyCode {
                case Self.upArrowKeyCode:
                    return self.handleSessionNav(direction: .up) ? nil : event
                case Self.downArrowKeyCode:
                    return self.handleSessionNav(direction: .down) ? nil : event
                default:
                    break
                }
            }

            // Cmd+Shift+Up or Cmd+Shift+L: jump to the session waiting longest.
            // Do not gate on text editing; this is a global navigation action.
            if held == [.command, .shift] {
                if [Self.upArrowKeyCode, Self.lKeyCode].contains(event.keyCode) {
                    return self.handleOldestWaitingSession() ? nil : event
                }
            }

            // Tab: jump to the session waiting longest.
            if held.isEmpty, event.keyCode == Self.tabKeyCode {
                return self.handleOldestWaitingSession() ? nil : event
            }

            return event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Select the Nth dispatcher in display order (Cmd+1 = first, etc.).
    /// Cmd+5 targets the preferred oc@ dispatcher if available.
    private func handleSlot(_ slot: Int) -> Bool {
        guard let directory = model?.directory else {
            NSSound.beep()
            return true
        }

        if let configuredTarget = model?.config?.switchDispatcherHotkeyTargets[slot] {
            if let matched = Self.dispatcherMatching(configuredTarget, in: directory.dispatchers) {
                directory.selectDispatcher(matched)
                return true
            }
            NSSound.beep()
            return true
        }

        if slot == 5 {
            if let oc = Self.defaultOCDispatcher(in: directory.dispatchers) {
                directory.selectDispatcher(oc)
                return true
            }
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

    static func defaultOCDispatcher(in dispatchers: [DirectoryItem]) -> DirectoryItem? {
        dispatchers.first { $0.jid.lowercased().hasPrefix("oc@") }
            ?? dispatchers.first { $0.name.lowercased().contains("opencode") }
            ?? dispatchers.first { $0.name.lowercased() == "oc" }
    }

    static func dispatcherMatching(_ target: String, in dispatchers: [DirectoryItem]) -> DirectoryItem? {
        let needle = target.lowercased()

        if let exact = dispatchers.first(where: { $0.jid.lowercased() == needle }) {
            return exact
        }

        if let byJidPrefix = dispatchers.first(where: { $0.jid.lowercased().hasPrefix(needle) }) {
            return byJidPrefix
        }

        return dispatchers.first(where: { $0.name.lowercased().hasPrefix(needle) })
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
