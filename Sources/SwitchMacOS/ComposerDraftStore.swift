import Foundation

@MainActor
final class ComposerDraftStore {
    private let defaultsKey = "switch.composerDraftsByJid.v1"
    private let defaults: UserDefaults

    private var draftsByJid: [String: String]
    private var pendingSave: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.draftsByJid = [:]
        load()
    }

    func draft(for jid: String) -> String {
        let key = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "" }
        return draftsByJid[key] ?? ""
    }

    func setDraft(_ text: String, for jid: String) {
        let key = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        if text.isEmpty {
            if draftsByJid[key] != nil {
                draftsByJid.removeValue(forKey: key)
                scheduleSave()
            }
            return
        }

        if draftsByJid[key] != text {
            draftsByJid[key] = text
            scheduleSave()
        }
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
    }

    private func scheduleSave() {
        pendingSave?.cancel()

        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.saveNow()
            }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func saveNow() {
        do {
            let data = try JSONEncoder().encode(draftsByJid)
            defaults.set(data, forKey: defaultsKey)
        } catch {
            // Best-effort; drafts are non-critical.
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey) else { return }
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        draftsByJid = decoded
    }
}
