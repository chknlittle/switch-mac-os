import AppKit
import SwiftUI
import SwitchCore

// MARK: - Menu (display-only, no keyboardShortcut since those are character-based and layout-dependent)

@MainActor
struct DispatcherHotkeysCommands: Commands {
    @ObservedObject var model: SwitchAppModel

    private let bindings = DispatcherHotkeyBindings.loadFromEnvironment()

    var body: some Commands {
        CommandMenu("Dispatchers") {
            dispatcherMenuItem(slot: 1, token: bindings.one)
            dispatcherMenuItem(slot: 2, token: bindings.two)
            dispatcherMenuItem(slot: 3, token: bindings.three)
            dispatcherMenuItem(slot: 4, token: bindings.four)
        }
    }

    @ViewBuilder
    private func dispatcherMenuItem(slot: Int, token: String?) -> some View {
        let tokenTrimmed = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = model.directory.flatMap { dir in
            resolveDispatcher(token: tokenTrimmed, dispatchers: dir.dispatchers)?.name
        }
        let display = resolvedName ?? (tokenTrimmed.isEmpty ? "Unassigned" : tokenTrimmed)

        Button("Select \(slot): \(display)  \u{2318}\(slot)") {
            guard let directory = model.directory else { return }
            guard let dispatcher = resolveDispatcher(token: tokenTrimmed, dispatchers: directory.dispatchers) else {
                NSSound.beep()
                return
            }
            directory.selectDispatcher(dispatcher)
        }
        .disabled(tokenTrimmed.isEmpty)
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
    private let bindings = DispatcherHotkeyBindings.loadFromEnvironment()

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

    private func handleSlot(_ slot: Int) -> Bool {
        let token: String?
        switch slot {
        case 1: token = bindings.one
        case 2: token = bindings.two
        case 3: token = bindings.three
        case 4: token = bindings.four
        default: return false
        }

        guard let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return false }
        guard let directory = model?.directory else {
            NSSound.beep()
            return true
        }
        guard let dispatcher = resolveDispatcher(token: t, dispatchers: directory.dispatchers) else {
            NSSound.beep()
            return true
        }
        directory.selectDispatcher(dispatcher)
        return true
    }
}

// MARK: - Shared resolution logic

func resolveDispatcher(token: String, dispatchers: [DirectoryItem]) -> DirectoryItem? {
    let t = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !t.isEmpty else { return nil }

    func lower(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    if let exact = dispatchers.first(where: { lower($0.jid) == t || lower($0.name) == t }) {
        return exact
    }
    if let byJidPrefix = dispatchers.first(where: { lower($0.jid).hasPrefix(t) }) {
        return byJidPrefix
    }
    if let byNamePrefix = dispatchers.first(where: { lower($0.name).hasPrefix(t) }) {
        return byNamePrefix
    }
    if let contains = dispatchers.first(where: { lower($0.jid).contains(t) || lower($0.name).contains(t) }) {
        return contains
    }
    return nil
}

// MARK: - Env bindings

private struct DispatcherHotkeyBindings {
    let one: String?
    let two: String?
    let three: String?
    let four: String?

    static func loadFromEnvironment() -> DispatcherHotkeyBindings {
        let env = EnvLoader.loadMergedEnv()
        func get(_ k: String) -> String? {
            let v = env[k]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty == false) ? v : nil
        }
        return DispatcherHotkeyBindings(
            one: get("SWITCH_DISPATCHER_HOTKEY_1"),
            two: get("SWITCH_DISPATCHER_HOTKEY_2"),
            three: get("SWITCH_DISPATCHER_HOTKEY_3"),
            four: get("SWITCH_DISPATCHER_HOTKEY_4")
        )
    }
}
