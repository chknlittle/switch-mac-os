import SwiftUI
import SwitchCore

struct RootView: View {
    @ObservedObject var model: SwitchAppModel

    var body: some View {
        Group {
            if let error = model.configError {
                ConfigErrorView(error: error)
            } else if let directory = model.directory {
                DirectoryShellView(directory: directory, xmpp: model.xmpp, chatStore: model.xmpp.chatStore)
            } else {
                NoDirectoryView(statusText: model.xmpp.statusText)
            }
        }
    }
}

private struct DirectoryShellView: View {
    @ObservedObject var directory: SwitchDirectoryService
    @ObservedObject var xmpp: XMPPService
    @ObservedObject var chatStore: ChatStore
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
                messages: messagesForActiveChat(),
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

    private func messagesForActiveChat() -> [ChatMessage] {
        guard let target = directory.chatTarget else { return [] }
        let jid: String
        switch target {
        case .dispatcher(let j), .individual(let j), .subagent(let j):
            jid = j
        }
        return chatStore.messages(for: jid)
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

    private let bottomAnchorId: String = "__bottom__"

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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(messages) { msg in
                                MessageRow(msg: msg)
                                    .id(msg.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorId)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .background(Color(NSColor.textBackgroundColor))
                    .onAppear {
                        scrollToBottom(using: proxy)
                    }
                    .onChange(of: messages.count) { _ in
                        scrollToBottom(using: proxy)
                    }
                    .onChange(of: messages.last?.id) { _ in
                        scrollToBottom(using: proxy)
                    }
                    .onChange(of: messages.last?.timestamp) { _ in
                        scrollToBottom(using: proxy)
                    }
                    .onChange(of: title) { _ in
                        scrollToBottom(using: proxy)
                    }
                }
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

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        guard isEnabled else { return }
        Task { @MainActor in
            withAnimation(nil) {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }

            // Layout can change after the first render (especially Markdown).
            await Task.yield()
            withAnimation(nil) {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation(nil) {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(nil) {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
        }
    }

    private struct MessageRow: View {
        let msg: ChatMessage

        var body: some View {
            HStack {
                if msg.direction == .outgoing {
                    Spacer(minLength: 32)
                }

                MarkdownMessage(content: msg.body)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: 520, alignment: msg.direction == .incoming ? .leading : .trailing)

                if msg.direction == .incoming {
                    Spacer(minLength: 32)
                }
            }
            .frame(maxWidth: .infinity, alignment: msg.direction == .incoming ? .leading : .trailing)
            .padding(.vertical, 4)
        }

        private var bubbleColor: Color {
            switch msg.direction {
            case .incoming:
                return Color.secondary.opacity(0.12)
            case .outgoing:
                return Color.accentColor.opacity(0.18)
            }
        }
    }
}

private struct MarkdownMessage: View {
    let content: String

    var bodyView: some View {
        let normalized = normalize(content)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(parseMarkdownBlocks(normalized), id: \.id) { block in
                switch block.kind {
                case .markdown(let s):
                    markdownText(s)
                case .code(let s, _):
                    codeBlock(s)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        bodyView
            .textSelection(.enabled)
    }

    private func markdownText(_ s: String) -> some View {
        let attr = (try? AttributedString(markdown: s)) ?? AttributedString(s)
        return Text(attr)
            .font(.system(size: 13, weight: .regular, design: .default))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(2)
    }

    private func normalize(_ s: String) -> String {
        // Normalize line endings first.
        var out = s
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")

        // Unescape common sequences that show up in logged/serialized output.
        // Example: "\\n" should render as a newline.
        if out.contains("\\") {
            out = out
                .replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\'", with: "'")
                .replacingOccurrences(of: "\\[", with: "[")
                .replacingOccurrences(of: "\\]", with: "]")
                .replacingOccurrences(of: "\\(", with: "(")
                .replacingOccurrences(of: "\\)", with: ")")
                .replacingOccurrences(of: "\\{", with: "{")
                .replacingOccurrences(of: "\\}", with: "}")
        }

        // If this looks like command/session logs, render as a single code block
        // to preserve whitespace exactly.
        if looksLikeLogs(out) {
            return "```text\n" + out + "\n```"
        }

        // Some models emit structured markdown without newlines between tokens
        // (e.g. "#IssueSeverity" or "1Duplicated"). This is hard to render
        // readably; insert a few safe breaks.
        out = out
            .replacingOccurrences(of: "#", with: "\n#")
            .replacingOccurrences(of: "—", with: " — ")

        return out
    }

    private func looksLikeLogs(_ s: String) -> Bool {
        // Heuristic: bracketed tool tags or timestamped lines.
        if s.contains("[Bash:") || s.contains("[Task]") || s.contains("[Glob]") || s.contains("[TodoWrite]") {
            return true
        }
        if s.contains("] Last") && s.contains("[00:") {
            return true
        }
        return false
    }

    private func codeBlock(_ s: String) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(s)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color.black.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private struct MarkdownBlock {
        enum Kind {
            case markdown(String)
            case code(String, lang: String?)
        }
        let id: String
        let kind: Kind
    }

    private func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var current: [String] = []
        var inCode = false
        var codeLang: String? = nil

        func flushMarkdown() {
            let s = current.joined(separator: "\n")
            current.removeAll(keepingCapacity: true)
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            blocks.append(MarkdownBlock(id: UUID().uuidString, kind: .markdown(s)))
        }

        func flushCode() {
            let s = current.joined(separator: "\n")
            current.removeAll(keepingCapacity: true)
            blocks.append(MarkdownBlock(id: UUID().uuidString, kind: .code(s, lang: codeLang)))
            codeLang = nil
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushMarkdown()
                    inCode = true
                    let lang = line.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLang = lang.isEmpty ? nil : lang
                }
                continue
            }
            current.append(line)
        }

        if inCode {
            flushCode()
        } else {
            flushMarkdown()
        }

        if blocks.isEmpty {
            blocks.append(MarkdownBlock(id: UUID().uuidString, kind: .markdown(text)))
        }

        return blocks
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
