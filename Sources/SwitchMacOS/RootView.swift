import SwiftUI
import SwitchCore

struct RootView: View {
    @ObservedObject var model: SwitchAppModel

    var body: some View {
        Group {
            if let error = model.configError {
                ConfigErrorView(error: error)
            } else if let directory = model.directory {
                DirectoryShellView(directory: directory, xmpp: model.xmpp)
            } else {
                NoDirectoryView(statusText: model.xmpp.statusText)
            }
        }
    }
}

private struct DirectoryShellView: View {
    @ObservedObject var directory: SwitchDirectoryService
    @ObservedObject var xmpp: XMPPService
    @State private var composerText: String = ""

    var body: some View {
        HSplitView {
            ColumnList(title: "Dispatchers", items: directory.dispatchers, selectedJid: directory.selectedDispatcherJid) { item in
                directory.selectDispatcher(item)
            }
            ColumnList(title: "Sessions", items: directory.individuals, selectedJid: directory.selectedSessionJid) { item in
                directory.selectIndividual(item)
            }

            ChatPane(
                title: chatTitle(target: directory.chatTarget),
                messages: directory.messagesForActiveChat(),
                composerText: $composerText,
                onSend: {
                    let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    directory.sendChat(body: trimmed)
                    composerText = ""
                },
                isEnabled: directory.chatTarget != nil
            )
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 10) {
                    Text(xmpp.statusText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Refresh") {
                        directory.refreshAll()
                    }
                }
            }
        }
    }

    private func chatTitle(target: ChatTarget?) -> String {
        guard let target else { return "Chat" }
        switch target {
        case .dispatcher(let jid):
            return "Dispatcher: \(jid)"
        case .individual(let jid):
            return "Session: \(jid)"
        case .subagent(let jid):
            return "Subagent: \(jid)"
        }
    }
}

private struct ColumnList: View {
    let title: String
    let items: [DirectoryItem]
    let selectedJid: String?
    let onSelect: (DirectoryItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            List(items) { item in
                Row(item: item, isSelected: isSelected(item))
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(item) }
                    .listRowSeparator(.hidden)
                    .listRowBackground(isSelected(item) ? Color.accentColor.opacity(0.16) : Color.clear)
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 180)
    }

    private func isSelected(_ item: DirectoryItem) -> Bool {
        return selectedJid == item.jid
    }

    private struct Row: View {
        let item: DirectoryItem
        let isSelected: Bool

        var body: some View {
            HStack(spacing: 8) {
                Text(item.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
    }
}

private struct ChatPane: View {
    let title: String
    let messages: [ChatMessage]
    @Binding var composerText: String
    let onSend: () -> Void
    let isEnabled: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if !isEnabled {
                EmptyChatView()
            } else {
                List(messages) { msg in
                    MessageRow(msg: msg)
                }
                .listStyle(.plain)
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Message", text: $composerText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isEnabled)
                Button("Send") { onSend() }
                    .disabled(!isEnabled || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 420)
    }

    private struct MessageRow: View {
        let msg: ChatMessage

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Text(msg.direction == .incoming ? "IN" : "OUT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(msg.direction == .incoming ? .secondary : .primary)
                    .frame(width: 34, alignment: .leading)
                Text(msg.body)
                    .font(.system(size: 13, weight: .regular, design: .default))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Select a dispatcher, then a session")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct ConfigErrorView: View {
    let error: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Missing Configuration")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(error)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Create a .env from .env.example in the repo root.")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct NoDirectoryView: View {
    let statusText: String

    var body: some View {
        VStack(spacing: 12) {
            Text("No Directory Service Configured")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(statusText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Set SWITCH_DIRECTORY_JID in .env to enable dispatcher + sessions lists.")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
