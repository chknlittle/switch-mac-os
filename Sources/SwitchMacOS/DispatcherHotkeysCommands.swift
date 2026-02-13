import AppKit
import SwiftUI
import SwitchCore

@MainActor
struct DispatcherHotkeysCommands: Commands {
    @ObservedObject var model: SwitchAppModel

    private let bindings = DispatcherHotkeyBindings.loadFromEnvironment()

    var body: some Commands {
        CommandMenu("Dispatchers") {
            dispatcherHotkeyButton(slot: 1, token: bindings.one, key: "1")
            dispatcherHotkeyButton(slot: 2, token: bindings.two, key: "2")
            dispatcherHotkeyButton(slot: 3, token: bindings.three, key: "3")
            dispatcherHotkeyButton(slot: 4, token: bindings.four, key: "4")
        }
    }

    @ViewBuilder
    private func dispatcherHotkeyButton(slot: Int, token: String?, key: KeyEquivalent) -> some View {
        let tokenTrimmed = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = model.directory.flatMap { dir in
            resolveDispatcher(token: tokenTrimmed, dispatchers: dir.dispatchers)?.name
        }
        let display = resolvedName ?? (tokenTrimmed.isEmpty ? "Unassigned" : tokenTrimmed)

        Button("Select \(slot): \(display)") {
            guard !tokenTrimmed.isEmpty else {
                NSSound.beep()
                return
            }
            guard let directory = model.directory else {
                NSSound.beep()
                return
            }
            guard let dispatcher = resolveDispatcher(token: tokenTrimmed, dispatchers: directory.dispatchers) else {
                NSSound.beep()
                return
            }
            directory.selectDispatcher(dispatcher)
            bringAppToFront()
        }
        .keyboardShortcut(key, modifiers: [.command])
        .disabled(tokenTrimmed.isEmpty)
    }

    private func bringAppToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.mainWindow ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func resolveDispatcher(token: String, dispatchers: [DirectoryItem]) -> DirectoryItem? {
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
}

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
