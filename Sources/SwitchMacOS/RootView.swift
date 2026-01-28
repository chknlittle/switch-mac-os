import AppKit
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
            ColumnList(
                title: "Dispatchers",
                items: directory.dispatchers,
                selectedJid: directory.selectedDispatcherJid,
                composingJids: directory.dispatchersWithComposingSessions
            ) { item in
                directory.selectDispatcher(item)
            }
            ColumnList(
                title: "Sessions",
                items: directory.individuals,
                selectedJid: directory.selectedSessionJid,
                composingJids: xmpp.composingJids
            ) { item in
                directory.selectIndividual(item)
            }

            ChatPane(
                title: chatTitle,
                messages: messagesForActiveChat(),
                composerText: $composerText,
                onSend: {
                    let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    directory.sendChat(body: trimmed)
                    composerText = ""
                },
                isEnabled: directory.chatTarget != nil,
                isTyping: isChatTargetTyping
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

    private var chatTitle: String {
        guard let target = directory.chatTarget else { return "Chat" }
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
        return chatStore.messages(for: target.jid)
    }

    private var isChatTargetTyping: Bool {
        guard let target = directory.chatTarget else { return false }
        return xmpp.composingJids.contains(target.jid)
    }
}

private struct ColumnList: View {
    let title: String
    let items: [DirectoryItem]
    let selectedJid: String?
    let composingJids: Set<String>
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
                Row(item: item, isSelected: isSelected(item), isComposing: composingJids.contains(item.jid))
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
        let isComposing: Bool

        var body: some View {
            HStack(spacing: 8) {
                Text(item.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isComposing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                }
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
    let isTyping: Bool

    private let bottomAnchorId: String = "__bottom__"
    private let composerMinHeight: CGFloat = 28
    private let composerMaxHeight: CGFloat = 160
    @State private var composerHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if isTyping {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                    Text("typing...")
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .foregroundStyle(.secondary)
                }
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
                ZStack(alignment: .topLeading) {
                    ComposerTextView(
                        text: $composerText,
                        measuredHeight: $composerHeight,
                        minHeight: composerMinHeight,
                        maxHeight: composerMaxHeight,
                        isEnabled: isEnabled,
                        onSubmit: onSend
                    )

                    if composerText.isEmpty {
                        Text("Message")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: composerHeight, maxHeight: composerHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                Button("Send") { onSend() }
                    .disabled(!isEnabled || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 420)
        .onChange(of: composerText) { newValue in
            if newValue.isEmpty {
                composerHeight = composerMinHeight
            }
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        guard isEnabled else { return }
        Task { @MainActor in
            func scrollNow() {
                withAnimation(nil) {
                    proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                }
            }

            scrollNow()

            // Layout can change after the first render (especially Markdown).
            await Task.yield()
            scrollNow()

            try? await Task.sleep(nanoseconds: 150_000_000)
            scrollNow()

            try? await Task.sleep(nanoseconds: 500_000_000)
            scrollNow()
        }
    }

    private struct MessageRow: View {
        let msg: ChatMessage

        private var isToolMessage: Bool {
            msg.meta?.isToolRelated ?? false
        }

        private var hasRunStats: Bool {
            msg.meta?.type == .runStats
        }

        var body: some View {
            HStack {
                if msg.direction == .outgoing {
                    Spacer(minLength: 32)
                }

                VStack(alignment: msg.direction == .incoming ? .leading : .trailing, spacing: 2) {
                    if isToolMessage {
                        toolMessageContent
                    } else {
                        MarkdownMessage(content: msg.body)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(bubbleColor)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .frame(maxWidth: 520, alignment: msg.direction == .incoming ? .leading : .trailing)
                    }

                    HStack(spacing: 6) {
                        if let tool = msg.meta?.tool {
                            Text(tool)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.8))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                        if let stats = msg.meta?.runStats {
                            runStatsView(stats)
                        }
                        Text(formatTimestamp(msg.timestamp))
                            .font(.system(size: 10, weight: .regular, design: .default))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    .padding(.horizontal, 4)
                }

                if msg.direction == .incoming {
                    Spacer(minLength: 32)
                }
            }
            .frame(maxWidth: .infinity, alignment: msg.direction == .incoming ? .leading : .trailing)
            .padding(.vertical, 4)
        }

        private var toolMessageContent: some View {
            Text(msg.body)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(Color.black.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: 520, alignment: .leading)
        }

        @ViewBuilder
        private func runStatsView(_ stats: RunStats) -> some View {
            HStack(spacing: 4) {
                if let model = stats.model {
                    Text(model)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
                if let tokensIn = stats.tokensIn, let tokensOut = stats.tokensOut {
                    Text("\(tokensIn)/\(tokensOut)tok")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                } else if let tokensTotal = stats.tokensTotal {
                    Text("\(tokensTotal)tok")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                }
                if let cost = stats.costUsd {
                    Text("$\(cost)")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                }
                if let duration = stats.durationS {
                    Text("\(duration)s")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                }
            }
            .foregroundStyle(.secondary.opacity(0.7))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }

        private var bubbleColor: Color {
            switch msg.direction {
            case .incoming:
                return Color.secondary.opacity(0.12)
            case .outgoing:
                return Color.accentColor.opacity(0.18)
            }
        }

        private func formatTimestamp(_ date: Date) -> String {
            let calendar = Calendar.current
            let now = Date()

            if calendar.isDateInToday(date) {
                let formatter = DateFormatter()
                formatter.dateFormat = "h:mm a"
                return formatter.string(from: date)
            } else if calendar.isDateInYesterday(date) {
                let formatter = DateFormatter()
                formatter.dateFormat = "h:mm a"
                return "Yesterday \(formatter.string(from: date))"
            } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEEE h:mm a"
                return formatter.string(from: date)
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d, h:mm a"
                return formatter.string(from: date)
            }
        }
    }
}

private final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var allowSubmit: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let isReturnKey = (event.keyCode == 36) || (event.keyCode == 76)
        let isShiftPressed = event.modifierFlags.contains(.shift)

        if isReturnKey, !isShiftPressed {
            if allowSubmit?() ?? true {
                onSubmit?()
                return
            }
        }

        super.keyDown(with: event)
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let isEnabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isSelectable = true
        textView.isEditable = isEnabled
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.font = .systemFont(ofSize: 13)
        textView.string = text
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.onSubmit = onSubmit
        textView.allowSubmit = { isEnabled }

        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.heightTracksTextView = false
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.updateHeightIfNeeded()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? SubmitTextView else { return }

        textView.isEditable = isEnabled
        textView.onSubmit = onSubmit
        textView.allowSubmit = { isEnabled }

        if textView.string != text {
            textView.string = text
        }

        context.coordinator.parent = self
        context.coordinator.textView = textView
        context.coordinator.updateHeightIfNeeded()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            updateHeightIfNeeded()
        }

        func textDidBeginEditing(_ notification: Notification) {
            updateHeightIfNeeded()
        }

        func updateHeightIfNeeded() {
            guard let tv = textView else { return }
            guard let container = tv.textContainer, let layout = tv.layoutManager else { return }

            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let rawHeight = used.height + tv.textContainerInset.height * 2

            let clamped = min(max(rawHeight, parent.minHeight), parent.maxHeight)
            if abs(parent.measuredHeight - clamped) > 0.5 {
                DispatchQueue.main.async {
                    self.parent.measuredHeight = clamped
                }
            }
        }
    }
}

private struct MarkdownMessage: View {
    let content: String

    var body: some View {
        let normalized = normalize(preprocess(content))

        VStack(alignment: .leading, spacing: 6) {
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
        .textSelection(.enabled)
    }

    private func markdownText(_ s: String) -> some View {
        // Split on \n\n for paragraph breaks, then render each paragraph
        // separately so spacing is controlled by the VStack, not by the
        // markdown parser (which collapses single \n into spaces).
        let paragraphs = s.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .init(charactersIn: "\n")) }
            .filter { !$0.isEmpty }

        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                if containsMarkdownSyntax(para) {
                    // For lines within a paragraph, convert \n to hard breaks.
                    let hardBreaks = para.replacingOccurrences(of: "\n", with: "  \n")
                    let attr = styleInlineCode((try? AttributedString(markdown: hardBreaks)) ?? AttributedString(para))
                    messageText(Text(attr))
                } else {
                    messageText(Text(verbatim: para))
                }
            }
        }
    }

    private func styleInlineCode(_ input: AttributedString) -> AttributedString {
        var result = input
        for run in result.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                let range = run.range
                result[range].backgroundColor = Color.accentColor.opacity(0.25)
                result[range].foregroundColor = Color.white
            }
        }
        return result
    }

    private func messageText(_ text: Text) -> some View {
        text
            .font(.system(size: 13.5, weight: .regular, design: .rounded))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(4)
    }

    private func containsMarkdownSyntax(_ s: String) -> Bool {
        // Cheap heuristics: prefer preserving plain text formatting unless the
        // author is clearly using Markdown.
        if s.contains("```") { return true }
        if s.contains("**") || s.contains("__") { return true }
        if s.contains("`") { return true }

        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { return true }
        if trimmed.hasPrefix(">") { return true }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return true }

        if s.contains("\n- ") || s.contains("\n* ") { return true }
        if s.contains("\n#") { return true }
        if s.contains("[ ") && s.contains("](") { return true }
        if s.contains("\n1. ") || s.contains("\n2. ") { return true }

        return false
    }

    private func normalize(_ s: String) -> String {
        // Normalize line endings only — don't mangle the content.
        return s
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    private func preprocess(_ s: String) -> String {
        // No content-based preprocessing needed - tool messages are now
        // identified via XMPP message metadata and rendered separately
        return s
    }

    private func codeBlock(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12.5, weight: .regular, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
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
