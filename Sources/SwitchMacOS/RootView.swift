import AppKit
import Combine
import CryptoKit
import Foundation
import LinkPresentation
import SwiftUI
import SwitchCore
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var model: SwitchAppModel

    var body: some View {
        Group {
            if let error = model.configError {
                ConfigErrorView(error: error)
            } else if let directory = model.directory {
                DirectoryShellView(
                    directory: directory,
                    xmpp: model.xmpp,
                    chatStore: model.xmpp.chatStore
                )
            } else {
                NoDirectoryView(statusText: model.xmpp.statusText)
            }
        }
    }
}

private struct DirectoryShellView: View {
    @ObservedObject var directory: SwitchDirectoryService
    @ObservedObject var xmpp: XMPPService
    let chatStore: ChatStore
    @State private var drafts = ComposerDraftStore()
    @StateObject private var activeThreadMessages = ActiveThreadMessagesModel()
    @State private var pendingImage: PendingImageAttachment? = nil
    @State private var pendingReply: PendingReplyTarget? = nil
    @State private var composerText: String = ""

    var body: some View {
        HSplitView {
            SidebarList(directory: directory, xmpp: xmpp, chatStore: chatStore)
                .frame(minWidth: 240)

            ChatPane(
                title: chatTitle,
                headerPrompt: sessionHeaderPrompt,
                threadJid: directory.chatTarget?.jid,
                messages: activeThreadMessages.messages,
                xmpp: xmpp,
                composerText: $composerText,
                pendingImage: $pendingImage,
                pendingReply: $pendingReply,
                onSend: {
                    let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let pending = pendingImage {
                        directory.sendImageAttachment(
                            data: pending.data,
                            filename: pending.filename,
                            mime: pending.mime,
                            caption: trimmed.isEmpty ? nil : trimmed,
                            replyTo: pendingReply?.reference
                        )
                        pendingImage = nil
                        pendingReply = nil
                        composerText = ""
                        return
                    }
                    guard !trimmed.isEmpty else { return }
                    directory.sendChat(body: trimmed, replyTo: pendingReply?.reference)
                    pendingReply = nil
                    composerText = ""
                },
                isEnabled: directory.chatTarget != nil,
                isTyping: isChatTargetTyping,
                encryptionStatus: xmpp.encryptionStatus(for: directory.chatTarget?.jid)
            )
        }
        .onAppear {
            chatStore.setActiveThread(directory.chatTarget?.jid)
            activeThreadMessages.attach(chatStore: chatStore)
            activeThreadMessages.setThreadJid(directory.chatTarget?.jid)
            loadDraftForActiveThread()
        }
        .onChange(of: directory.chatTarget?.jid) { newValue in
            chatStore.setActiveThread(newValue)
            activeThreadMessages.setThreadJid(newValue)
            pendingReply = nil
            loadDraftForActiveThread()
        }
        .onChange(of: composerText) { newValue in
            guard let jid = directory.chatTarget?.jid else { return }
            drafts.setDraft(newValue, for: jid)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            drafts.flush()
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 8, height: 8)
                    Text(xmpp.statusText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chatTitle: String {
        guard let target = directory.chatTarget else { return "Chat" }
        switch target {
        case .dispatcher(let jid):
            if let item = directory.dispatchers.first(where: { $0.jid == jid }) {
                return "Dispatcher: \(item.name)"
            }
            return "Dispatcher: \(jid)"
        case .individual(let jid):
            if let item = directory.individuals.first(where: { $0.jid == jid }), item.isGroup {
                return "Group Session: \(jid)"
            }
            return "Session: \(jid)"
        case .subagent(let jid):
            return "Subagent: \(jid)"
        }
    }

    private var sessionHeaderPrompt: String? {
        guard let target = directory.chatTarget else { return nil }
        guard case .individual(let jid) = target else { return nil }
        guard let item = directory.individuals.first(where: { $0.jid == jid }) else { return nil }
        // Directory item names are often the prompt/label used to start the session.
        // If the server didn't provide one, DirectoryItem falls back to the JID.
        let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed != jid else { return nil }
        return trimmed
    }

    private var statusDotColor: Color {
        switch xmpp.status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected, .error: return .red
        }
    }

    private var isChatTargetTyping: Bool {
        guard let target = directory.chatTarget else { return false }
        return xmpp.composingJids.contains(target.jid)
    }

    private func loadDraftForActiveThread() {
        guard let jid = directory.chatTarget?.jid else {
            composerText = ""
            return
        }
        composerText = drafts.draft(for: jid)
    }
}

@MainActor
private final class ActiveThreadMessagesModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []

    private weak var chatStore: ChatStore?
    private var threadJid: String?
    private var cancellables: Set<AnyCancellable> = []

    func attach(chatStore: ChatStore) {
        if self.chatStore === chatStore {
            return
        }

        self.chatStore = chatStore
        cancellables.removeAll()

        chatStore.threadMessagesUpdated
            .sink { [weak self] updatedThreadJid in
                guard let self else { return }
                guard updatedThreadJid == self.threadJid else { return }
                guard let store = self.chatStore else { return }
                self.messages = store.messages(for: updatedThreadJid)
            }
            .store(in: &cancellables)

        setThreadJid(threadJid)
    }

    func setThreadJid(_ jid: String?) {
        threadJid = jid
        guard let store = chatStore, let jid else {
            messages = []
            return
        }
        messages = store.messages(for: jid)
    }
}

private struct SidebarList: View {
    @ObservedObject var directory: SwitchDirectoryService
    @ObservedObject var xmpp: XMPPService
    @ObservedObject var chatStore: ChatStore

    private enum ScrollAnchor {
        static let bottom = "__bottom__"
    }

    private struct BottomMarkerMinYKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    @State private var scrollViewHeight: CGFloat = 0
    @State private var bottomMarkerMinY: CGFloat = 0
    @State private var stickToBottom: Bool = true
    @State private var didInitialScroll: Bool = false

    private var selectedDispatcherName: String? {
        guard let dispatcherJid = directory.selectedDispatcherJid else { return nil }
        return directory.dispatchers.first(where: { $0.jid == dispatcherJid })?.name ?? dispatcherJid
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                ZStack(alignment: .bottomTrailing) {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 0) {
                                Spacer(minLength: 0)

                                LazyVStack(alignment: .leading, spacing: 0) {
                                    if !directory.individuals.isEmpty {
                                        // directory.individuals is sorted: active (by recency) then closed.
                                        // Reversed so oldest-active at top, newest-active at bottom.
                                        // Closed sessions appear at the very top.
                                        let reversed = Array(directory.individuals.reversed())
                                        let closedItems = reversed.filter { $0.isClosed }
                                        let activeItems = reversed.filter { !$0.isClosed }

                                        if !closedItems.isEmpty {
                                            Text("Recent")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 14)
                                                .padding(.top, 6)
                                                .padding(.bottom, 2)

                                            ForEach(closedItems) { item in
                                                sessionRow(item)
                                                    .opacity(0.6)
                                            }

                                            if !activeItems.isEmpty {
                                                Divider()
                                                    .padding(.horizontal, 14)
                                                    .padding(.vertical, 4)
                                            }
                                        }

                                        ForEach(activeItems) { item in
                                            sessionRow(item)
                                        }
                                    } else {
                                        SidebarPlaceholderRow(
                                            title: directory.isLoadingIndividuals ? "Loading sessions..." : "No sessions",
                                            subtitle: directory.isLoadingIndividuals ? nil : "Send a message to start a session",
                                            isLoading: directory.isLoadingIndividuals
                                        )
                                        .padding(.horizontal, 10)
                                        .transaction { txn in
                                            txn.animation = nil
                                        }
                                    }

                                    Color.clear
                                        .frame(height: 1)
                                        .id(ScrollAnchor.bottom)
                                        .background(
                                            GeometryReader { g in
                                                Color.clear.preference(
                                                    key: BottomMarkerMinYKey.self,
                                                    value: g.frame(in: .named("sessionsScroll")).minY
                                                )
                                            }
                                        )
                                }
                            }
                            // When the list is too short to fill the viewport, keep it anchored
                            // to the bottom and put the empty space at the top.
                            .frame(minHeight: g.size.height, alignment: .bottom)
                            .padding(.bottom, 10)
                        }
                        .coordinateSpace(name: "sessionsScroll")
                        .onAppear {
                            scrollViewHeight = g.size.height
                            // Scroll when sessions appear; this handles the "start at bottom" expectation.
                            DispatchQueue.main.async {
                                proxy.scrollTo(ScrollAnchor.bottom, anchor: .bottom)
                            }
                        }
                        .onChange(of: g.size.height) { newValue in
                            scrollViewHeight = newValue
                        }
                        .onPreferenceChange(BottomMarkerMinYKey.self) { newValue in
                            bottomMarkerMinY = newValue
                            let atBottom = bottomMarkerMinY <= scrollViewHeight + 16
                            stickToBottom = atBottom
                        }
                        .onChange(of: directory.selectedDispatcherJid) { _ in
                            // Switching dispatchers changes the sessions set; default to bottom again.
                            didInitialScroll = false
                            stickToBottom = true
                            DispatchQueue.main.async {
                                proxy.scrollTo(ScrollAnchor.bottom, anchor: .bottom)
                            }
                        }
                        .onChange(of: directory.individuals.count) { _ in
                            guard stickToBottom else { return }
                            DispatchQueue.main.async {
                                if didInitialScroll {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        proxy.scrollTo(ScrollAnchor.bottom, anchor: .bottom)
                                    }
                                } else {
                                    proxy.scrollTo(ScrollAnchor.bottom, anchor: .bottom)
                                    didInitialScroll = true
                                }
                            }
                        }
                    }

                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    SidebarSectionHeader(title: "Dispatchers", detail: selectedDispatcherName)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            let composingDispatchers = directory.dispatchersWithComposingSessions
                            let unreadByDispatcher = dispatcherUnreadCounts()
                            if directory.dispatchers.isEmpty {
                                Text("Loading dispatchers...")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(directory.dispatchers) { item in
                                    let isSelected = directory.selectedDispatcherJid == item.jid
                                    let isComposing = composingDispatchers.contains(item.jid)
                                    let unreadCount = isComposing ? 0 : (unreadByDispatcher[item.jid] ?? 0)

                                    Button {
                                        directory.selectDispatcher(item)
                                    } label: {
                                        ZStack(alignment: .topTrailing) {
                                            ZStack(alignment: .bottomTrailing) {
                                                AvatarCircle(imageData: xmpp.avatarDataByJid[item.jid], fallbackText: item.name)
                                                    .scaleEffect(1.2)
                                                    .frame(width: 30, height: 30)
                                                    .overlay(
                                                        Circle()
                                                            .stroke(isSelected ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 2)
                                                    )

                                                if isComposing {
                                                    ProgressView()
                                                        .scaleEffect(0.35)
                                                        .frame(width: 10, height: 10)
                                                        .padding(1)
                                                        .background(Color(NSColor.controlBackgroundColor))
                                                        .clipShape(Circle())
                                                        .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                                                        .offset(x: 6, y: 6)
                                                }
                                            }

                                            if unreadCount > 0 {
                                                UnreadBadge(count: unreadCount)
                                                    .scaleEffect(0.75)
                                                    .offset(x: 10, y: -10)
                                            }
                                        }
                                        .frame(width: 30, height: 30)
                                        .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(item.name)
                                    .onAppear {
                                        xmpp.ensureAvatarLoaded(for: item.jid)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
        .background(TintedSurface(base: Theme.windowBg, tint: Theme.accent, opacity: 0.055))
    }

    @ViewBuilder
    private func sessionRow(_ item: DirectoryItem) -> some View {
        let isComposing = xmpp.composingJids.contains(item.jid)
        SidebarRow(
            title: item.name,
            subtitle: nil,
            leadingSymbolName: item.isGroup ? "person.2.fill" : nil,
            showAvatar: false,
            avatarData: nil,
            isSelected: directory.selectedSessionJid == item.jid,
            isComposing: isComposing,
            unreadCount: isComposing ? 0 : chatStore.unreadCount(for: item.jid),
            onCancel: {
                xmpp.sendMessage(to: item.jid, body: "/cancel")
            },
            onCopyName: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.name, forType: .string)
            },
            onResume: {
                directory.resumeSession(item)
            }
        ) {
            directory.selectIndividual(item)
        }
        .id(item.jid)
        .padding(.horizontal, 10)
    }

    private func dispatcherUnreadCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(directory.dispatchers.count)
        for item in directory.dispatchers {
            counts[item.jid] = directory.unreadCountForDispatcher(item.jid, unreadByThread: chatStore.unreadByThread)
        }
        return counts
    }
}

private struct SidebarPlaceholderRow: View {
    let title: String
    let subtitle: String?
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent.opacity(0.62))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .regular, design: .default))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .allowsHitTesting(false)
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let count: Int?
    let detail: String?

    init(title: String, count: Int? = nil, detail: String? = nil) {
        self.title = title
        self.count = count
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))

            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.chipBg)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Theme.chipBorder, lineWidth: 1)
                    )
                    .clipShape(Capsule(style: .continuous))
            }
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }
}

private struct SidebarRow: View {
    let title: String
    let subtitle: String?
    let leadingSymbolName: String?
    let showAvatar: Bool
    let avatarData: Data?
    let isSelected: Bool
    let isComposing: Bool
    let unreadCount: Int
    let onCancel: (() -> Void)?
    let onCopyName: (() -> Void)?
    let onResume: (() -> Void)?
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            if showAvatar {
                AvatarCircle(imageData: avatarData, fallbackText: title)
            }
            if let leadingSymbolName {
                Image(systemName: leadingSymbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isComposing {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
                if let onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Send /cancel")
                }
            }
            if isHovering && !isComposing {
                if let onResume {
                    Button(action: onResume) {
                        Image(systemName: "arrow.forward.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Resume in new session")
                }
                if let onCopyName {
                    Button(action: onCopyName) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy session name")
                }
            }
            if unreadCount > 0 {
                UnreadBadge(count: unreadCount)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0 }
        .background(isSelected ? Theme.selectedRow : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct AvatarCircle: View {
    let imageData: Data?
    let fallbackText: String

    private var fallbackInitial: String {
        let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first {
            return String(first).uppercased()
        }
        return "?"
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accentSubtle)

            if let imageData, let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(fallbackInitial)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(Theme.border, lineWidth: 1)
        )
    }
}

private struct UnreadBadge: View {
    let count: Int

    private var label: String {
        if count > 99 { return "99+" }
        return String(count)
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.badgeBg)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Theme.badgeBorder, lineWidth: 1)
            )
            .clipShape(Capsule())
    }
}

// MARK: - Color Theme

private enum Theme {
    // ── Core accent ──────────────────────────────────
    static var accent: Color {
        Color(nsColor: .controlAccentColor)
    }

    // ── Surfaces ─────────────────────────────────────
    static var windowBg: Color {
        Color(nsColor: .windowBackgroundColor)
    }
    static var surfacePrimary: Color {
        Color(nsColor: .controlBackgroundColor)
    }
    static var surfaceRaised: Color {
        Color(nsColor: .underPageBackgroundColor)
    }

    // ── Text ─────────────────────────────────────────
    static var textPrimary: Color {
        Color(nsColor: .labelColor)
    }
    static var textSecondary: Color {
        Color(nsColor: .secondaryLabelColor)
    }
    static var textTertiary: Color {
        Color(nsColor: .tertiaryLabelColor)
    }

    // ── Borders / separators ─────────────────────────
    static var separator: Color {
        Color(nsColor: .separatorColor)
    }
    static var border: Color {
        Color(nsColor: .tertiaryLabelColor).opacity(0.3)
    }

    // ── Semantic accents (flat tints) ────────────────
    static var accentSubtle: Color { accent.opacity(0.11) }
    static var accentMedium: Color { accent.opacity(0.21) }
    static var accentStrong: Color { accent.opacity(0.34) }

    // ── Bubbles ──────────────────────────────────────
    static var bubbleIncoming: Color { surfaceRaised }
    static var bubbleOutgoing: Color { accentMedium }

    // ── Interactive states ───────────────────────────
    static var selectedRow: Color { accent.opacity(0.13) }

    // ── Badges / chips ───────────────────────────────
    static var badgeBg: Color { accentSubtle }
    static var badgeBorder: Color { accent.opacity(0.18) }
    static var chipBg: Color { accentSubtle }
    static var chipBorder: Color { accent.opacity(0.12) }

    // ── Code ─────────────────────────────────────────
    static var codeBg: Color {
        Color(nsColor: .textBackgroundColor).opacity(0.6)
    }
    static var codeInlineBg: Color { accent.opacity(0.12) }
}

private struct TintedSurface: View {
    let base: Color
    let tint: Color
    let opacity: Double

    var body: some View {
        ZStack {
            base
            tint.opacity(opacity).blendMode(.softLight)
        }
    }
}

private struct PendingImageAttachment {
    let data: Data
    let filename: String
    let mime: String
    let preview: NSImage

    static func from(fileUrl: URL) -> PendingImageAttachment? {
        guard fileUrl.isFileURL else { return nil }
        let filename = fileUrl.lastPathComponent
        guard let data = try? Data(contentsOf: fileUrl) else { return nil }
        return from(imageData: data, defaultFilename: filename, fileUrl: fileUrl)
    }

    static func from(firstImageAt urls: [URL]) -> PendingImageAttachment? {
        for url in urls {
            if let pending = from(fileUrl: url) {
                return pending
            }
        }
        return nil
    }

    static func from(nsImage: NSImage) -> PendingImageAttachment? {
        guard let data = pngData(from: nsImage) else { return nil }
        let filename = "pasted-\(Int(Date().timeIntervalSince1970)).png"
        return PendingImageAttachment(data: data, filename: filename, mime: "image/png", preview: nsImage)
    }

    static func from(imageData: Data, defaultFilename: String, fileUrl: URL? = nil) -> PendingImageAttachment? {
        guard let preview = NSImage(data: imageData) else { return nil }

        let type: UTType?
        if let fileUrl {
            type = UTType(filenameExtension: fileUrl.pathExtension)
        } else {
            type = UTType(filenameExtension: URL(fileURLWithPath: defaultFilename).pathExtension)
        }
        let mime = type?.preferredMIMEType ?? "image/png"

        return PendingImageAttachment(data: imageData, filename: defaultFilename, mime: mime, preview: preview)
    }

    static func urlFromDropItem(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let str = item as? String {
            return URL(string: str)
        }
        return nil
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation else { return nil }
        guard let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private struct PendingReplyTarget {
    let reference: MessageReplyReference
    let preview: String
    let isIncoming: Bool

    static func from(message: ChatMessage, localBareJid: String) -> PendingReplyTarget {
        let text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = text.replacingOccurrences(of: "\n", with: " ")
        let preview: String
        if compact.isEmpty {
            preview = "(attachment)"
        } else if compact.count > 120 {
            preview = String(compact.prefix(120)) + "..."
        } else {
            preview = compact
        }

        let repliedToJid: String
        switch message.direction {
        case .incoming:
            repliedToJid = message.threadJid
        case .outgoing:
            repliedToJid = localBareJid
        }

        return PendingReplyTarget(
            reference: MessageReplyReference(id: message.id, to: repliedToJid),
            preview: preview,
            isIncoming: message.direction == .incoming
        )
    }
}

private struct PendingImageRow: View {
    let pending: PendingImageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: pending.preview)
                .resizable()
                .scaledToFill()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(pending.filename)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(pending.mime)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PendingReplyRow: View {
    let reply: PendingReplyTarget
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(reply.isIncoming ? "Replying to them" : "Replying to you")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(reply.preview)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ChatPane: View {
    let title: String
    let headerPrompt: String?
    let threadJid: String?
    let messages: [ChatMessage]
    let xmpp: XMPPService
    @Binding var composerText: String
    @Binding var pendingImage: PendingImageAttachment?
    @Binding var pendingReply: PendingReplyTarget?
    let onSend: () -> Void
    let isEnabled: Bool
    let isTyping: Bool
    let encryptionStatus: XMPPService.ThreadEncryptionStatus?

    private let bottomAnchorId: String = "__bottom__"
    private let composerMinHeight: CGFloat = 28
    private let composerMaxHeight: CGFloat = 160
    @State private var composerHeight: CGFloat = 28
    @State private var scrollTask: Task<Void, Never>? = nil
    @State private var isDropTarget: Bool = false
    @State private var isTranscriptMode: Bool = false

    var body: some View {
        let messagesById = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if let headerPrompt, !headerPrompt.isEmpty {
                        Text(headerPrompt)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        if let encryptionStatus {
                            encryptionChip(encryptionStatus)
                        }
                        if isTyping {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 14, height: 14)
                            Text("typing...")
                                .font(.system(size: 11, weight: .regular, design: .default))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let encryptionDetail {
                        Text(encryptionDetail)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(encryptionDetailColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                Button(isTranscriptMode ? "Done" : "Select") {
                    isTranscriptMode.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Select text across messages")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if !isEnabled {
                EmptyChatView()
            } else {
                if isTranscriptMode {
                    TranscriptTextView(text: transcriptText(messages))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                        .background(
                            TintedSurface(
                                base: Color(NSColor.textBackgroundColor),
                                tint: Theme.accent,
                                opacity: 0.03
                            )
                        )
                        .id((threadJid ?? "__no_thread__") + "__transcript__")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                                    MessageRow(
                                        msg: msg,
                                        repliedMessage: msg.replyTo.flatMap { messagesById[$0.id] },
                                        showTimestamp: shouldShowTimestamp(for: index),
                                        xmpp: xmpp,
                                        onReply: { tapped in
                                            pendingReply = PendingReplyTarget.from(message: tapped, localBareJid: xmpp.client.userBareJid.stringValue)
                                        }
                                    )
                                        .id(msg.id)
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id(bottomAnchorId)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                        .background(
                            ZStack {
                                TintedSurface(
                                    base: Color(NSColor.textBackgroundColor),
                                    tint: Theme.accent,
                                    opacity: 0.03
                                )
                            }
                        )
                        // Force a fresh scroll view per thread so switching chats
                        // doesn't carry over scroll position.
                        .id(threadJid ?? "__no_thread__")
                        .task(id: threadJid) {
                            scrollToBottom(using: proxy)
                        }
                        .onChange(of: messages.last?.id) { _ in
                            scrollToBottom(using: proxy)
                        }
                    }
                }
            }

            Divider()

            VStack(spacing: 8) {
                if let pendingReply {
                    PendingReplyRow(reply: pendingReply) {
                        self.pendingReply = nil
                    }
                }

                if let pendingImage {
                    PendingImageRow(pending: pendingImage) {
                        self.pendingImage = nil
                    }
                }

                HStack(spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        ComposerTextView(
                            text: $composerText,
                            measuredHeight: $composerHeight,
                            minHeight: composerMinHeight,
                            maxHeight: composerMaxHeight,
                            isEnabled: isEnabled,
                            onPasteImage: { img in
                                if let pending = PendingImageAttachment.from(nsImage: img) {
                                    self.pendingImage = pending
                                }
                            },
                            onPasteFileUrls: { urls in
                                if let pending = PendingImageAttachment.from(firstImageAt: urls) {
                                    self.pendingImage = pending
                                }
                            },
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
                            .stroke(isDropTarget ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    Button("Send") { onSend() }
                        .disabled(!isEnabled || !hasSendableContent)
                }
            }
            .padding(10)
            .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $isDropTarget) { providers in
                handleDrop(providers)
            }
        }
        .frame(minWidth: 420)
        .background(TintedSurface(base: Theme.windowBg, tint: Theme.accent, opacity: 0.04))
        .onChange(of: composerText) { newValue in
            if newValue.isEmpty {
                composerHeight = composerMinHeight
            }
        }
        .onChange(of: threadJid) { _ in
            pendingImage = nil
            pendingReply = nil
            isTranscriptMode = false
        }
    }

    @ViewBuilder
    private func encryptionChip(_ status: XMPPService.ThreadEncryptionStatus) -> some View {
        switch status {
        case .encrypted:
            Label("Encrypted", systemImage: "lock.fill")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.green)
        case .requiredUnavailable(let reason):
            Label(reason, systemImage: "lock.slash")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.red)
                .lineLimit(2)
        case .decryptionFailed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
                .lineLimit(2)
        case .cleartext:
            Label("Cleartext", systemImage: "lock.open")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var encryptionDetail: String? {
        guard let encryptionStatus else { return nil }
        switch encryptionStatus {
        case .requiredUnavailable(let reason):
            return reason
        case .decryptionFailed(let reason):
            return reason
        case .cleartext, .encrypted:
            return nil
        }
    }

    private var encryptionDetailColor: Color {
        guard let encryptionStatus else { return .secondary }
        switch encryptionStatus {
        case .requiredUnavailable:
            return .red.opacity(0.9)
        case .decryptionFailed:
            return .orange.opacity(0.9)
        case .cleartext, .encrypted:
            return .secondary
        }
    }

    private var hasSendableContent: Bool {
        if pendingImage != nil { return true }
        return !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard isEnabled else { return false }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = PendingImageAttachment.urlFromDropItem(item) else { return }
                if let pending = PendingImageAttachment.from(fileUrl: url) {
                    DispatchQueue.main.async {
                        self.pendingImage = pending
                    }
                }
            }
            return true
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                if let pending = PendingImageAttachment.from(imageData: data, defaultFilename: "dropped.png") {
                    DispatchQueue.main.async {
                        self.pendingImage = pending
                    }
                }
            }
            return true
        }

        return false
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        guard isEnabled else { return }
        guard !isTranscriptMode else { return }

        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            func scrollNow() {
                withAnimation(nil) {
                    proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                }
            }

            scrollNow()

            // Layout can change after the first render (especially Markdown).
            await Task.yield()
            scrollNow()

            try? await Task.sleep(nanoseconds: 120_000_000)
            scrollNow()
        }
    }

    private func transcriptText(_ messages: [ChatMessage]) -> String {
        func trimTrailingNewlines(_ s: String) -> String {
            var out = s
            while out.hasSuffix("\n") {
                out.removeLast()
            }
            return out
        }

        func formatMessage(_ msg: ChatMessage) -> String {
            let who = msg.direction == .outgoing ? "you" : "them"
            let body = trimTrailingNewlines(msg.body)

            if msg.meta?.type == .attachment, let atts = msg.meta?.attachments, !atts.isEmpty {
                let lines = atts.map { att in
                    let name = att.filename ?? att.publicUrl ?? att.localPath ?? "attachment"
                    return "- " + name
                }
                if body.isEmpty {
                    return "[" + who + "] attachments\n" + lines.joined(separator: "\n")
                }
                return "[" + who + "] " + body + "\n" + lines.joined(separator: "\n")
            }

            if msg.meta?.type == .question, let q = msg.meta?.question {
                let qs = q.questions.compactMap { $0.question ?? $0.header }.filter { !$0.isEmpty }
                if !qs.isEmpty {
                    let rendered = qs.map { "- " + $0 }.joined(separator: "\n")
                    if body.isEmpty {
                        return "[" + who + "] question\n" + rendered
                    }
                    return "[" + who + "] " + body + "\n" + rendered
                }
            }

            if body.isEmpty {
                return "[" + who + "]"
            }

            return "[" + who + "] " + body
        }

        var parts: [String] = []
        parts.reserveCapacity(messages.count)
        for msg in messages {
            parts.append(formatMessage(msg))
        }
        return parts.joined(separator: "\n\n")
    }

    private func shouldShowTimestamp(for index: Int) -> Bool {
        guard messages.indices.contains(index) else { return false }
        guard index < messages.count - 1 else { return true }

        let current = messages[index]
        let next = messages[index + 1]

        if current.direction != next.direction {
            return true
        }

        let gap = next.timestamp.timeIntervalSince(current.timestamp)
        return gap >= 5 * 60
    }

    private struct MessageRow: View {
        let msg: ChatMessage
        let repliedMessage: ChatMessage?
        let showTimestamp: Bool
        let xmpp: XMPPService
        let onReply: (ChatMessage) -> Void

        private var isToolMessage: Bool {
            msg.meta?.isToolRelated ?? false
        }

        var body: some View {
            let inferredImageAttachments = inferredInlineImageAttachments(from: msg.body)
            let inferredPreviewURL = inferredLinkPreviewURL(from: msg.body)

            HStack {
                if msg.direction == .outgoing {
                    Spacer(minLength: 32)
                }

                VStack(alignment: msg.direction == .incoming ? .leading : .trailing, spacing: 2) {
                    if let replyLine = replyPreviewLine {
                        HStack(spacing: 6) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.35))
                                .frame(width: 2)
                            Text(replyLine)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.09))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .frame(maxWidth: 520, alignment: msg.direction == .incoming ? .leading : .trailing)
                    }

                    if msg.direction == .incoming, let q = msg.meta?.question, msg.meta?.type == .question {
                        QuestionCard(envelope: q) { answers, displayText in
                            xmpp.sendQuestionReply(
                                to: msg.threadJid,
                                requestId: q.requestId,
                                answers: answers,
                                displayText: displayText
                            )
                        }
                        .frame(maxWidth: 520, alignment: .leading)
                    } else
                    if msg.meta?.type == .attachment, let atts = msg.meta?.attachments, !atts.isEmpty {
                        AttachmentMessageView(attachments: atts, bodyText: msg.body, direction: msg.direction)
                            .frame(maxWidth: 520, alignment: msg.direction == .incoming ? .leading : .trailing)
                    } else
                    if !inferredImageAttachments.isEmpty {
                        AttachmentMessageView(attachments: inferredImageAttachments, bodyText: msg.body, direction: msg.direction)
                            .frame(maxWidth: 520, alignment: msg.direction == .incoming ? .leading : .trailing)
                    } else
                    if let inferredPreviewURL {
                        LinkPreviewMessageView(url: inferredPreviewURL, bodyText: msg.body, direction: msg.direction)
                            .frame(maxWidth: 520, alignment: msg.direction == .incoming ? .leading : .trailing)
                    } else
                    if isToolMessage {
                        toolMessageContent
                    } else {
                        MarkdownMessage(content: msg.body, xhtmlBody: msg.xhtmlBody)
                            .equatable()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(bubbleColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(bubbleBorder, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .frame(maxWidth: 520, alignment: msg.direction == .incoming ? .leading : .trailing)
                    }

                    if msg.meta?.tool != nil || msg.meta?.runStats != nil || showTimestamp {
                        HStack(spacing: 6) {
                            switch msg.encryption {
                            case .encrypted, .decrypted:
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.green.opacity(0.9))
                            case .decryptionFailed:
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.orange.opacity(0.9))
                            case .cleartext:
                                EmptyView()
                            }
                            if let tool = msg.meta?.tool {
                                Text(tool)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary.opacity(0.8))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Theme.chipBg)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .stroke(Theme.chipBorder, lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            }
                            if let stats = msg.meta?.runStats {
                                runStatsView(stats)
                            }
                            if showTimestamp {
                                Text(formatTimestamp(msg.timestamp))
                                    .font(.system(size: 10, weight: .regular, design: .default))
                                    .foregroundStyle(.secondary.opacity(0.7))
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }

                if msg.direction == .incoming {
                    Spacer(minLength: 32)
                }
            }
            .frame(maxWidth: .infinity, alignment: msg.direction == .incoming ? .leading : .trailing)
            .padding(.vertical, 4)
            .contextMenu {
                Button("Reply") {
                    onReply(msg)
                }
            }
        }

        private var replyPreviewLine: String? {
            guard let reply = msg.replyTo else { return nil }

            let body: String
            if let repliedMessage {
                body = repliedMessage.body
            } else {
                body = "message unavailable"
            }

            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let compact = trimmed.replacingOccurrences(of: "\n", with: " ")
            let snippet: String
            if compact.isEmpty {
                snippet = "(empty message)"
            } else if compact.count > 92 {
                snippet = String(compact.prefix(92)) + "..."
            } else {
                snippet = compact
            }

            if let to = reply.to, !to.isEmpty {
                return "\(to): \(snippet)"
            }
            return snippet
        }

        private var toolMessageContent: some View {
            Text(msg.body)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(Theme.codeBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: 520, alignment: .leading)
        }

        private func inferredInlineImageAttachments(from body: String) -> [SwitchAttachment] {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(body.startIndex..., in: body)
            let matches = detector?.matches(in: body, options: [], range: range) ?? []

            var attachments: [SwitchAttachment] = []
            var seenUrls: Set<String> = []

            for match in matches {
                guard let url = match.url else { continue }
                guard isInlineRenderableImageURL(url) else { continue }

                let key = url.absoluteString
                if seenUrls.contains(key) { continue }
                seenUrls.insert(key)

                let filename = url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
                let mime: String?
                if let type = UTType(filenameExtension: url.pathExtension) {
                    mime = type.preferredMIMEType
                } else {
                    mime = nil
                }

                attachments.append(
                    SwitchAttachment(
                        id: "inline-url:\(key)",
                        kind: "image",
                        mime: mime,
                        publicUrl: key,
                        filename: filename
                    )
                )
            }

            for raw in extractAESGCMUrls(from: body) {
                guard let url = URL(string: raw) else { continue }
                guard isInlineRenderableImageURL(url) else { continue }
                if seenUrls.contains(raw) { continue }
                seenUrls.insert(raw)

                let filename = url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
                let mime: String?
                if let type = UTType(filenameExtension: url.pathExtension) {
                    mime = type.preferredMIMEType
                } else {
                    mime = nil
                }

                attachments.append(
                    SwitchAttachment(
                        id: "inline-url:\(raw)",
                        kind: "image",
                        mime: mime,
                        publicUrl: raw,
                        filename: filename
                    )
                )
            }

            return attachments
        }

        private func inferredLinkPreviewURL(from body: String) -> URL? {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(body.startIndex..., in: body)
            let matches = detector?.matches(in: body, options: [], range: range) ?? []

            for match in matches {
                guard let url = match.url else { continue }
                guard is9GagPreviewURL(url) else { continue }
                return url
            }

            return nil
        }

        private func is9GagPreviewURL(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return false
            }
            guard let host = url.host?.lowercased(), host.hasSuffix("9gag.com") else {
                return false
            }
            return url.path.lowercased().hasPrefix("/gag/")
        }

        private func extractAESGCMUrls(from text: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: "aesgcm://[^\\s]+#[0-9A-Fa-f]{88}") else {
                return []
            }
            let range = NSRange(text.startIndex..., in: text)
            return regex.matches(in: text, options: [], range: range).compactMap { match in
                guard let swiftRange = Range(match.range, in: text) else { return nil }
                return String(text[swiftRange])
            }
        }

        private func isInlineRenderableImageURL(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "file" || scheme == "aesgcm" else {
                return false
            }

            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty else { return false }

            if let type = UTType(filenameExtension: ext) {
                return type.conforms(to: .image)
            }

            return false
        }

        @ViewBuilder
        private func runStatsView(_ stats: RunStats) -> some View {
            VStack(alignment: .leading, spacing: 2) {
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
                    if let cost = formattedCost(stats.costUsd) {
                        Text("$\(cost)")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                    }
                    if let duration = formattedDuration(stats.durationS) {
                        Text("\(duration)s")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                    }
                    if let tps = runTokensPerSecond(stats) {
                        Text("\(tps)t/s")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                    }
                }

                if let summary = condensedSummary(stats.summary) {
                    Text(summary)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                }
            }
            .foregroundStyle(.secondary.opacity(0.7))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }

        private func runTokensPerSecond(_ stats: RunStats) -> String? {
            guard let duration = numericValue(stats.durationS), duration > 0 else { return nil }

            // Prefer overall throughput (total processed tokens) over pure output
            // throughput so TPS better matches operator expectations for long-context runs.
            let tokensFromTotal = numericValue(stats.tokensTotal)
            let tokensFromInOut: Double? = {
                guard let tokensIn = numericValue(stats.tokensIn),
                      let tokensOut = numericValue(stats.tokensOut) else { return nil }
                return tokensIn + tokensOut
            }()
            let tokens = tokensFromTotal ?? tokensFromInOut ?? numericValue(stats.tokensOut)
            guard let tokens, tokens > 0 else { return nil }
            return String(format: "%.1f", tokens / duration)
        }

        private func formattedDuration(_ raw: String?) -> String? {
            guard let value = numericValue(raw), value > 0 else { return nil }
            return String(format: "%.1f", value)
        }

        private func formattedCost(_ raw: String?) -> String? {
            guard let value = numericValue(raw), value >= 0 else { return nil }
            return String(format: "%.3f", value)
        }

        private func condensedSummary(_ raw: String?) -> String? {
            guard var summary = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
                return nil
            }

            if summary.hasPrefix("["), let close = summary.firstIndex(of: "]") {
                let tail = summary[summary.index(after: close)...]
                summary = String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
                while summary.hasPrefix("|") || summary.hasPrefix("-") {
                    summary.removeFirst()
                    summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            return summary.isEmpty ? nil : summary
        }

        private func numericValue(_ raw: String?) -> Double? {
            guard let raw else { return nil }
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "$", with: "")
            return Double(cleaned)
        }

        private var bubbleColor: Color {
            switch msg.direction {
            case .incoming:
                return Theme.bubbleIncoming
            case .outgoing:
                return Theme.bubbleOutgoing
            }
        }

        private var bubbleBorder: Color {
            switch msg.direction {
            case .incoming:
                return Theme.border
            case .outgoing:
                return Theme.accentStrong
            }
        }

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter
        }()

        private static let weekdayTimeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE h:mm a"
            return formatter
        }()

        private static let fullFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, h:mm a"
            return formatter
        }()

        private func formatTimestamp(_ date: Date) -> String {
            let calendar = Calendar.current

            if calendar.isDateInToday(date) {
                return Self.timeFormatter.string(from: date)
            }
            if calendar.isDateInYesterday(date) {
                return "Yesterday \(Self.timeFormatter.string(from: date))"
            }
            if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
                return Self.weekdayTimeFormatter.string(from: date)
            }
            return Self.fullFormatter.string(from: date)
        }
    }

    private struct AttachmentMessageView: View {
        let attachments: [SwitchAttachment]
        let bodyText: String
        let direction: ChatMessage.Direction

        var body: some View {
            let images = attachments.filter { isImage($0) }
            let caption = extractCaption(bodyText: bodyText, attachments: images)

            VStack(alignment: direction == .incoming ? .leading : .trailing, spacing: 8) {
                if let caption, !caption.isEmpty {
                    MarkdownMessage(content: caption, xhtmlBody: nil)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(bubbleColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(bubbleBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if !images.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(images.prefix(4)) { att in
                            AttachmentThumbnail(att: att)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(attachments.prefix(6)) { att in
                            Button(action: { openAttachment(att) }) {
                                Text(att.filename ?? att.publicUrl ?? att.localPath ?? "Attachment")
                                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(bubbleBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }

        private func isImage(_ att: SwitchAttachment) -> Bool {
            if let mime = att.mime?.lowercased(), mime.hasPrefix("image/") { return true }
            if let kind = att.kind?.lowercased(), kind == "image" { return true }
            if let fn = att.filename?.lowercased() {
                if fn.hasSuffix(".png") || fn.hasSuffix(".jpg") || fn.hasSuffix(".jpeg") || fn.hasSuffix(".gif") || fn.hasSuffix(".webp") || fn.hasSuffix(".heic") {
                    return true
                }
            }
            return false
        }

        private func extractCaption(bodyText: String, attachments: [SwitchAttachment]) -> String? {
            let t = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }

            let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.count >= 2, let last = lines.last, looksLikeUrl(last) {
                let url = last.trimmingCharacters(in: .whitespacesAndNewlines)
                if attachments.contains(where: { $0.publicUrl == url }) {
                    let captionLines = lines.dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    return captionLines.isEmpty ? nil : captionLines
                }
            }

            if looksLikeUrl(t), attachments.contains(where: { $0.publicUrl == t }) {
                return nil
            }

            return t
        }

        private func looksLikeUrl(_ s: String) -> Bool {
            guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return u.scheme == "http" || u.scheme == "https" || u.scheme == "file" || u.scheme == "aesgcm"
        }

        private var bubbleColor: Color {
            switch direction {
            case .incoming:
                return Theme.bubbleIncoming
            case .outgoing:
                return Theme.bubbleOutgoing
            }
        }

        private var bubbleBorder: Color {
            switch direction {
            case .incoming:
                return Theme.border
            case .outgoing:
                return Theme.accentStrong
            }
        }

        private func openAttachment(_ att: SwitchAttachment) {
            if let s = att.publicUrl {
                AttachmentThumbnail.openAttachment(publicUrl: s, localPath: att.localPath, filename: att.filename)
                return
            }
            if let p = att.localPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: p))
                return
            }
        }

        private struct AttachmentThumbnail: View {
            let att: SwitchAttachment
            @State private var aesgcmImage: NSImage? = nil
            @State private var aesgcmFileURL: URL? = nil
            @State private var isDecrypting: Bool = false
            @State private var decryptFailed: Bool = false

            var body: some View {
                let source = bestSource()

                Button(action: { open() }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.10))

                        if let source {
                            switch source {
                            case .file(let url):
                                if let img = NSImage(contentsOf: url) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    placeholder
                                }
                            case .remote(let url):
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .empty:
                                        placeholder
                                    case .failure:
                                        placeholder
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFill()
                                    @unknown default:
                                        placeholder
                                    }
                                }
                            case .aesgcm:
                                if let img = aesgcmImage {
                                    Image(nsImage: img)
                                        .resizable()
                                        .scaledToFill()
                                } else if isDecrypting {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else if decryptFailed {
                                    placeholder
                                } else {
                                    placeholder
                                }
                            }
                        } else {
                            placeholder
                        }
                    }
                    .frame(width: 180, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .task(id: source?.cacheKey ?? att.id) {
                    await loadAESGCMPreviewIfNeeded(source: source)
                }
            }

            private var placeholder: some View {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(att.filename ?? "image")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 160)
                }
            }

            private func open() {
                let source = bestSource()
                switch source {
                case .file(let url):
                    NSWorkspace.shared.open(url)
                case .remote(let url):
                    NSWorkspace.shared.open(url)
                case .aesgcm(let descriptor):
                    Task {
                        if let existing = aesgcmFileURL {
                            await MainActor.run {
                                NSWorkspace.shared.open(existing)
                            }
                            return
                        }

                        if let file = try? await Self.resolveAESGCMFile(descriptor: descriptor) {
                            await MainActor.run {
                                aesgcmFileURL = file
                                NSWorkspace.shared.open(file)
                            }
                        }
                    }
                case .none:
                    break
                }
            }

            @MainActor
            private func loadAESGCMPreviewIfNeeded(source: ThumbnailSource?) async {
                guard case .aesgcm(let descriptor) = source else { return }
                if aesgcmImage != nil || isDecrypting { return }

                isDecrypting = true
                defer { isDecrypting = false }

                do {
                    let data = try await Self.decryptAESGCM(descriptor: descriptor)
                    if let img = NSImage(data: data) {
                        aesgcmImage = img
                    }
                    aesgcmFileURL = try await Self.cacheDecryptedFile(data: data, descriptor: descriptor)
                    decryptFailed = false
                } catch {
                    decryptFailed = true
                }
            }

            private func bestSource() -> ThumbnailSource? {
                if let s = att.publicUrl,
                   let descriptor = Self.parseAESGCMDescriptor(from: s, fallbackFilename: att.filename) {
                    return .aesgcm(descriptor)
                }
                if let s = att.publicUrl, let u = URL(string: s) {
                    return .remote(u)
                }
                if let p = att.localPath {
                    return .file(URL(fileURLWithPath: p))
                }
                return nil
            }

            static func openAttachment(publicUrl: String?, localPath: String?, filename: String?) {
                if let publicUrl,
                   let descriptor = parseAESGCMDescriptor(from: publicUrl, fallbackFilename: filename) {
                    Task {
                        if let file = try? await resolveAESGCMFile(descriptor: descriptor) {
                            await MainActor.run {
                                NSWorkspace.shared.open(file)
                            }
                        }
                    }
                    return
                }

                if let publicUrl, let u = URL(string: publicUrl) {
                    NSWorkspace.shared.open(u)
                    return
                }
                if let localPath {
                    NSWorkspace.shared.open(URL(fileURLWithPath: localPath))
                }
            }

            private enum ThumbnailSource: Hashable {
                case file(URL)
                case remote(URL)
                case aesgcm(AESGCMDescriptor)

                var cacheKey: String {
                    switch self {
                    case .file(let url):
                        return "file:\(url.path)"
                    case .remote(let url):
                        return "remote:\(url.absoluteString)"
                    case .aesgcm(let descriptor):
                        return "aesgcm:\(descriptor.rawURL)"
                    }
                }
            }

            private struct AESGCMDescriptor: Hashable {
                let rawURL: String
                let downloadURL: URL
                let iv: Data
                let key: Data
                let filename: String?
            }

            private static let decryptedDataCache = NSCache<NSString, NSData>()

            private static func parseAESGCMDescriptor(from raw: String, fallbackFilename: String?) -> AESGCMDescriptor? {
                guard var components = URLComponents(string: raw),
                      components.scheme?.lowercased() == "aesgcm",
                      let fragment = components.fragment,
                      fragment.count == 88,
                      let bytes = decodeHex(fragment),
                      bytes.count == 44 else {
                    return nil
                }

                let iv = bytes.prefix(12)
                let key = bytes.dropFirst(12)

                components.scheme = "https"
                components.fragment = nil
                guard let downloadURL = components.url else { return nil }

                let inferredName = downloadURL.lastPathComponent.isEmpty ? nil : downloadURL.lastPathComponent
                return AESGCMDescriptor(
                    rawURL: raw,
                    downloadURL: downloadURL,
                    iv: Data(iv),
                    key: Data(key),
                    filename: fallbackFilename ?? inferredName
                )
            }

            private static func decodeHex(_ s: String) -> Data? {
                let chars = Array(s)
                if chars.count % 2 != 0 { return nil }

                var out = Data(capacity: chars.count / 2)
                var i = 0
                while i < chars.count {
                    let hi = chars[i]
                    let lo = chars[i + 1]
                    guard let high = hexValue(hi), let low = hexValue(lo) else { return nil }
                    out.append((high << 4) | low)
                    i += 2
                }
                return out
            }

            private static func hexValue(_ c: Character) -> UInt8? {
                guard let value = UInt8(String(c), radix: 16) else { return nil }
                return value
            }

            private static func decryptAESGCM(descriptor: AESGCMDescriptor) async throws -> Data {
                if let cached = decryptedDataCache.object(forKey: descriptor.rawURL as NSString) {
                    return Data(referencing: cached)
                }

                let (ciphertextWithTag, response) = try await URLSession.shared.data(from: descriptor.downloadURL)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw NSError(domain: "AESGCMDownload", code: http.statusCode)
                }

                guard ciphertextWithTag.count >= 17 else {
                    throw NSError(domain: "AESGCMDecrypt", code: 1)
                }

                let ciphertext = ciphertextWithTag.dropLast(16)
                let tag = ciphertextWithTag.suffix(16)
                let nonce = try AES.GCM.Nonce(data: descriptor.iv)
                let key = SymmetricKey(data: descriptor.key)
                let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
                let plain = try AES.GCM.open(sealed, using: key)

                let data = Data(plain)
                decryptedDataCache.setObject(NSData(data: data), forKey: descriptor.rawURL as NSString)
                return data
            }

            private static func resolveAESGCMFile(descriptor: AESGCMDescriptor) async throws -> URL {
                let data = try await decryptAESGCM(descriptor: descriptor)
                return try await cacheDecryptedFile(data: data, descriptor: descriptor)
            }

            private static func cacheDecryptedFile(data: Data, descriptor: AESGCMDescriptor) async throws -> URL {
                let fm = FileManager.default
                let dir = fm.temporaryDirectory.appendingPathComponent("switch-aesgcm", isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)

                let digest = SHA256.hash(data: Data(descriptor.rawURL.utf8)).map { String(format: "%02x", $0) }.joined()
                let ext: String = {
                    if let filename = descriptor.filename,
                       let parsed = URL(string: filename),
                       !parsed.pathExtension.isEmpty {
                        return parsed.pathExtension
                    }
                    if let filename = descriptor.filename,
                       !URL(fileURLWithPath: filename).pathExtension.isEmpty {
                        return URL(fileURLWithPath: filename).pathExtension
                    }
                    if !descriptor.downloadURL.pathExtension.isEmpty {
                        return descriptor.downloadURL.pathExtension
                    }
                    return "bin"
                }()

                let fileURL = dir.appendingPathComponent("\(digest).\(ext)")
                if !fm.fileExists(atPath: fileURL.path) {
                    try data.write(to: fileURL, options: [.atomic])
                }
                return fileURL
            }
        }
    }

    private struct LinkPreviewMessageView: View {
        let url: URL
        let bodyText: String
        let direction: ChatMessage.Direction

        var body: some View {
            VStack(alignment: direction == .incoming ? .leading : .trailing, spacing: 8) {
                if let caption {
                    MarkdownMessage(content: caption, xhtmlBody: nil)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(bubbleColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(bubbleBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                LinkPreviewCard(url: url)
                    .frame(width: 360, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
                    )
            }
        }

        private var caption: String? {
            let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed == url.absoluteString { return nil }
            return trimmed
        }

        private var bubbleColor: Color {
            switch direction {
            case .incoming:
                return Theme.bubbleIncoming
            case .outgoing:
                return Theme.bubbleOutgoing
            }
        }

        private var bubbleBorder: Color {
            switch direction {
            case .incoming:
                return Theme.border
            case .outgoing:
                return Theme.accentStrong
            }
        }
    }

    private struct LinkPreviewCard: View {
        let url: URL
        @State private var metadata: LPLinkMetadata? = nil
        @State private var isLoading: Bool = false

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))

                if let metadata {
                    LPLinkViewRepresentable(metadata: metadata)
                } else if isLoading {
                    ProgressView()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(url.absoluteString)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10)
                    }
                }
            }
            .task(id: url.absoluteString) {
                await loadMetadataIfNeeded()
            }
        }

        @MainActor
        private func loadMetadataIfNeeded() async {
            if metadata != nil || isLoading { return }
            isLoading = true

            let provider = LPMetadataProvider()
            provider.timeout = 10

            await withCheckedContinuation { continuation in
                provider.startFetchingMetadata(for: url) { result, _ in
                    Task { @MainActor in
                        metadata = result
                        isLoading = false
                        continuation.resume()
                    }
                }
            }
        }
    }

    private struct LPLinkViewRepresentable: NSViewRepresentable {
        let metadata: LPLinkMetadata

        func makeNSView(context: Context) -> LPLinkView {
            let view = LPLinkView(metadata: metadata)
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }

        func updateNSView(_ nsView: LPLinkView, context: Context) {
            nsView.metadata = metadata
        }
    }

    private struct QuestionCard: View {
        let envelope: SwitchQuestionEnvelopeV1
        let onSend: (_ answers: [[String]]?, _ displayText: String) -> Void

        @State private var selections: [[String]]
        @State private var freeText: [String]
        @State private var sent: Bool = false

        init(envelope: SwitchQuestionEnvelopeV1, onSend: @escaping (_ answers: [[String]]?, _ displayText: String) -> Void) {
            self.envelope = envelope
            self.onSend = onSend
            _selections = State(initialValue: Array(repeating: [], count: envelope.questions.count))
            _freeText = State(initialValue: Array(repeating: "", count: envelope.questions.count))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Question")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(envelope.engine ?? "")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("v\(envelope.version ?? 1)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ForEach(envelope.questions.indices, id: \.self) { idx in
                    let q = envelope.questions[idx]
                    let opts = q.options ?? []
                    let isMultiple = q.multiple ?? false

                    VStack(alignment: .leading, spacing: 8) {
                        if let header = q.header, !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(header)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        } else if envelope.questions.count > 1 {
                            Text("\(idx + 1))")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }

                        if let text = q.question, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(text)
                                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if opts.isEmpty {
                            TextField("Type your answer", text: bindingFreeText(idx))
                                .textFieldStyle(.roundedBorder)
                                .disabled(sent)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(opts.indices, id: \.self) { oIdx in
                                    let opt = opts[oIdx]
                                    optionRow(
                                        label: opt.label,
                                        description: opt.description,
                                        isSelected: selections[idx].contains(opt.label),
                                        isEnabled: !sent,
                                        onTap: {
                                            toggleOption(questionIndex: idx, label: opt.label, multiple: isMultiple)
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.top, idx == 0 ? 0 : 6)
                }

                Divider()

                HStack(spacing: 10) {
                    Text("rid: \(envelope.requestId)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if sent {
                        Text("Sent")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Reply") {
                            let answers = buildAnswers()
                            let display = buildDisplayText(from: answers)
                            onSend(answers, display)
                            sent = true
                        }
                        .disabled(!hasAnyInput)
                    }
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private var hasAnyInput: Bool {
            for i in envelope.questions.indices {
                if !(selections[i].isEmpty) { return true }
                if !freeText[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            }
            return false
        }

        private func bindingFreeText(_ idx: Int) -> Binding<String> {
            Binding(
                get: { freeText[idx] },
                set: { freeText[idx] = $0 }
            )
        }

        private func toggleOption(questionIndex: Int, label: String, multiple: Bool) {
            if sent { return }
            if multiple {
                if let i = selections[questionIndex].firstIndex(of: label) {
                    selections[questionIndex].remove(at: i)
                } else {
                    selections[questionIndex].append(label)
                }
            } else {
                if selections[questionIndex] == [label] {
                    selections[questionIndex] = []
                } else {
                    selections[questionIndex] = [label]
                }
            }
        }

        private func buildAnswers() -> [[String]]? {
            var answers: [[String]] = []
            answers.reserveCapacity(envelope.questions.count)

            for idx in envelope.questions.indices {
                let opts = envelope.questions[idx].options ?? []
                if opts.isEmpty {
                    let t = freeText[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                    answers.append(t.isEmpty ? [] : [t])
                } else {
                    answers.append(selections[idx])
                }
            }

            return answers
        }

        private func buildDisplayText(from answers: [[String]]?) -> String {
            let a = answers ?? []
            if envelope.questions.count <= 1 {
                let s = (a.first ?? []).joined(separator: ", ")
                return s.isEmpty ? "(no answer)" : s
            }

            var lines: [String] = []
            for i in 0..<min(envelope.questions.count, a.count) {
                let s = a[i].joined(separator: ", ")
                if !s.isEmpty {
                    lines.append("\(i + 1)) \(s)")
                }
            }
            return lines.isEmpty ? "(no answer)" : lines.joined(separator: "\n")
        }

        private func optionRow(label: String, description: String?, isSelected: Bool, isEnabled: Bool, onTap: @escaping () -> Void) -> some View {
            Button(action: onTap) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(description)
                                .font(.system(size: 11.5, weight: .regular, design: .default))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
    }
}

private struct TranscriptTextView: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.heightTracksTextView = false
        }
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        // Avoid blowing away an in-progress selection while the user is copying.
        if textView.selectedRange.length > 0 {
            return
        }

        if context.coordinator.lastText != text {
            context.coordinator.lastText = text
            textView.string = text
            textView.scrollToEndOfDocument(nil)
        }
    }

    final class Coordinator {
        var lastText: String = ""
    }
}

private final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var allowSubmit: (() -> Bool)?
    var onPasteImage: ((NSImage) -> Void)?
    var onPasteFileUrls: (([URL]) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // SwiftUI/AppKit key equivalent routing can be finicky; ensure Cmd+V triggers
        // our custom paste handler whenever this view is focused.
        if event.modifierFlags.contains(.command),
           (event.charactersIgnoringModifiers ?? "").lowercased() == "v"
        {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

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

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let imageFileUrls = urls.filter { url in
                guard url.isFileURL else { return false }
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .image)
            }
            if !imageFileUrls.isEmpty {
                onPasteFileUrls?(imageFileUrls)
                return
            }
        }

        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           let promise = promises.first
        {
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("switch-paste-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            promise.receivePromisedFiles(atDestination: tmpDir, options: [:], operationQueue: .main) { url, _ in
                self.onPasteFileUrls?([url])
            }
            return
        }

        // NSImage(pasteboard:) can miss common clipboard formats (e.g. PNG screenshots).
        if let img = NSImage(pasteboard: pb) {
            onPasteImage?(img)
            return
        }

        // Some clipboard images (including screenshots) are easiest to decode from raw raster
        // representations (commonly TIFF on macOS).
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            let img = NSImage(size: rep.size)
            img.addRepresentation(rep)
            onPasteImage?(img)
            return
        }

        if let items = pb.pasteboardItems {
            for item in items {
                for t in item.types {
                    let id = t.rawValue
                    guard let ut = UTType(id), ut.conforms(to: .image) else { continue }
                    guard let data = item.data(forType: t) ?? pb.data(forType: t) else { continue }
                    if let img = NSImage(data: data) {
                        onPasteImage?(img)
                        return
                    }
                }
            }
        }

        // Last resort: scan pasteboard-level types for any image-conforming UTI.
        for t in pb.types ?? [] {
            let id = t.rawValue
            guard let ut = UTType(id), ut.conforms(to: .image) else { continue }
            guard let data = pb.data(forType: t) else { continue }
            if let img = NSImage(data: data) {
                onPasteImage?(img)
                return
            }
        }
        super.paste(sender)
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let isEnabled: Bool
    let onPasteImage: ((NSImage) -> Void)?
    let onPasteFileUrls: (([URL]) -> Void)?
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
        textView.onPasteImage = onPasteImage
        textView.onPasteFileUrls = onPasteFileUrls

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
        textView.onPasteImage = onPasteImage
        textView.onPasteFileUrls = onPasteFileUrls

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

private struct MarkdownMessage: View, Equatable {
    let content: String
    let xhtmlBody: String?

    var body: some View {
        if let xhtmlBody,
           shouldUseXHTML(xhtmlBody: xhtmlBody, content: content),
           let rich = htmlText(xhtmlBody) {
            return messageText(rich)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }

        let normalized = normalize(content)

        // Render as a single Text view so selection can span paragraphs and code blocks.
        // SwiftUI text selection does not extend across multiple Text views.
        let blocks = parseMarkdownBlocks(normalized)
        var combined = Text("")
        for i in blocks.indices {
            let block = blocks[i]
            switch block.kind {
            case .markdown(let s):
                combined = combined + markdownText(s)
            case .code(let s):
                combined = combined + codeBlockText(s)
            }
            if i != blocks.indices.last {
                combined = combined + Text("\n\n")
            }
        }
        return messageText(combined)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func htmlText(_ html: String) -> Text? {
        guard let data = html.data(using: .utf8) else {
            return nil
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let ns = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }

        let trimmed = trimTrailingNewlines(ns)
        guard !trimmed.string.isEmpty else {
            return nil
        }

        if let attr = try? AttributedString(trimmed, including: \.appKit) {
            return Text(attr)
        }
        return Text(trimmed.string)
    }

    private func shouldUseXHTML(xhtmlBody: String, content: String) -> Bool {
        let html = xhtmlBody.lowercased()
        let contentLooksInlineMarkdown =
            content.contains("**") ||
            content.contains("__") ||
            content.contains("`")

        let xhtmlHasInlineStyling =
            html.contains("<strong") ||
            html.contains("<b>") ||
            html.contains("<em") ||
            html.contains("<code") ||
            html.contains("<pre")

        if contentLooksInlineMarkdown && !xhtmlHasInlineStyling {
            // Prefer markdown rendering when XHTML is only structural and would
            // otherwise show literal inline markdown markers like **bold** or `code`.
            return false
        }
        return true
    }

    private func trimTrailingNewlines(_ input: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: input)
        let ns = mutable.string as NSString
        var end = ns.length
        while end > 0 {
            let ch = ns.substring(with: NSRange(location: end - 1, length: 1))
            if ch == "\n" || ch == "\r" {
                end -= 1
                continue
            }
            break
        }
        if end < mutable.length {
            mutable.deleteCharacters(in: NSRange(location: end, length: mutable.length - end))
        }
        return mutable
    }

    private func markdownText(_ s: String) -> Text {
        // Split on \n\n for paragraph breaks, then render each paragraph
        // separately so spacing is controlled by the VStack, not by the
        // markdown parser (which collapses single \n into spaces).
        let paragraphs = s.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .init(charactersIn: "\n")) }
            .filter { !$0.isEmpty }

        var combined = Text("")
        for i in paragraphs.indices {
            let para = paragraphs[i]
            if containsMarkdownSyntax(para) && !containsBlockMarkdownSyntax(para) {
                // Inline markdown only. For lines within a paragraph, convert \n to hard breaks.
                // (SwiftUI's markdown rendering tends to collapse single \n into spaces.)
                let hardBreaks = para.replacingOccurrences(of: "\n", with: "  \n")
                let attr = styleInlineCode((try? AttributedString(markdown: hardBreaks)) ?? AttributedString(para))
                combined = combined + Text(attr)
            } else {
                // Preserve literal layout (lists/quotes/headings/newlines) instead of letting the
                // markdown pipeline collapse block separators.
                if para.contains("`") || para.contains("**") || para.contains("__") {
                    combined = combined + Text(styleVerbatimInlineMarkup(para))
                } else {
                    combined = combined + Text(verbatim: para)
                }
            }
            if i != paragraphs.indices.last {
                combined = combined + Text("\n\n")
            }
        }
        return combined
    }

    private func makeInlineCodeSpan(_ s: String) -> AttributedString {
        // Match the same "pill" styling used by `styleInlineCode`.
        // AttributedString background has no padding; use a thin space to create
        // minimal horizontal breathing room without the "wide" look of a full space.
        let pad = "\u{200A}" // hair space
        var out = AttributedString(pad + s + pad)
        out.backgroundColor = Color.accentColor.opacity(0.22)
        out.foregroundColor = Color.white
        out.font = .system(size: 12.75, weight: .medium, design: .monospaced)
        out.kern = 0
        return out
    }

    private func makeBoldSpan(_ s: String) -> AttributedString {
        var out = AttributedString(s)
        // Make emphasis visually unambiguous.
        out.font = .system(size: 13.5, weight: .bold, design: .rounded)
        out.inlinePresentationIntent = .stronglyEmphasized
        return out
    }

    private func styleVerbatimInlineMarkup(_ s: String) -> AttributedString {
        // Render a subset of markdown inline markup while keeping the text verbatim:
        // - `inline code`
        // - **bold** / __bold__
        // This avoids SwiftUI's markdown block rendering which can collapse newlines.
        let input = formatListMarkers(s)
        var out = AttributedString("")
        var idx = input.startIndex

        func appendLiteral(_ start: String.Index, _ end: String.Index) {
            if end > start {
                out += AttributedString(String(input[start..<end]))
            }
        }

        while idx < input.endIndex {
            let nextBacktick = input[idx...].firstIndex(of: "`")
            let nextBoldA = input[idx...].range(of: "**")?.lowerBound
            let nextBoldB = input[idx...].range(of: "__")?.lowerBound

            // Pick earliest delimiter.
            var next = nextBacktick
            var kind: String = "code"
            if let a = nextBoldA {
                if next == nil || a < next! {
                    next = a
                    kind = "bold**"
                }
            }
            if let b = nextBoldB {
                if next == nil || b < next! {
                    next = b
                    kind = "bold__"
                }
            }

            guard let open = next else {
                appendLiteral(idx, input.endIndex)
                break
            }

            appendLiteral(idx, open)

            if kind == "code" {
                let afterOpen = input.index(after: open)
                guard let close = input[afterOpen...].firstIndex(of: "`") else {
                    out += AttributedString("`")
                    idx = afterOpen
                    continue
                }
                let code = String(input[afterOpen..<close])
                out += makeInlineCodeSpan(code)
                idx = input.index(after: close)
                continue
            }

            let delim = (kind == "bold__") ? "__" : "**"
            let afterDelim = input.index(open, offsetBy: 2)
            guard let closeRange = input[afterDelim...].range(of: delim) else {
                out += AttributedString(delim)
                idx = afterDelim
                continue
            }

            let inner = String(input[afterDelim..<closeRange.lowerBound])
            out += makeBoldSpan(inner)
            idx = closeRange.upperBound
        }

        return out
    }

    private func formatListMarkers(_ s: String) -> String {
        // Convert common unordered list markers to a bullet glyph while keeping
        // the rest of the text verbatim.
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let bullet = "\u{2022}"
        let out = lines.map { raw -> String in
            let leading = raw.prefix { $0 == " " || $0 == "\t" }
            let rest = raw.dropFirst(leading.count)
            if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
                let after = rest.dropFirst(2)
                return String(leading) + bullet + " " + after
            }
            return raw
        }
        return out.joined(separator: "\n")
    }

    private func containsBlockMarkdownSyntax(_ s: String) -> Bool {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
            if line.hasPrefix(">") { return true }
            if line.hasPrefix("#") { return true }

            // Ordered list: "1. ..."
            var idx = line.startIndex
            while idx < line.endIndex, line[idx].isNumber {
                idx = line.index(after: idx)
            }
            if idx != line.startIndex, idx < line.endIndex {
                if line[idx] == "." {
                    let afterDot = line.index(after: idx)
                    if afterDot < line.endIndex, line[afterDot] == " " {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func codeBlockText(_ s: String) -> Text {
        // Use an attributed-string fallback for code blocks so selection can span across
        // the whole message. We can't get proper padding/rounded corners like a SwiftUI
        // container, so we fake padding by adding spaces on each line.
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out = AttributedString("")
        for i in lines.indices {
            let raw = lines[i]
            var line = AttributedString("  \(raw)  ")
            line.font = .system(size: 12.5, weight: .regular, design: .monospaced)
            line.foregroundColor = Color.primary
            line.backgroundColor = Color.black.opacity(0.06)
            out += line
            if i != lines.indices.last {
                out += AttributedString("\n")
            }
        }
        return Text(out)
    }

    private func styleInlineCode(_ input: AttributedString) -> AttributedString {
        var result = input
        // Find code ranges and style them
        var codeRanges: [Range<AttributedString.Index>] = []
        for run in result.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                codeRanges.append(run.range)
            }
        }
        // Apply styling to code ranges.
        // NOTE: AttributedString's background has no padding or rounded corners.
        // To create readable "pills", we wrap the span with a thin padding and apply
        // the background to the padded content.
        for range in codeRanges.reversed() {
            let inner = AttributedString(result[range])
            let pad = AttributedString("\u{200A}") // hair space
            var styled = pad + inner + pad
            styled.backgroundColor = Color.accentColor.opacity(0.22)
            styled.foregroundColor = Color.white
            styled.font = .system(size: 12.75, weight: .medium, design: .monospaced)
            styled.kern = 0
            result.replaceSubrange(range, with: styled)
        }
        return result
    }

    private func messageText(_ text: Text) -> some View {
        text
            .font(.system(size: 13.5, weight: .regular, design: .rounded))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(7)
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

    private struct MarkdownBlock {
        enum Kind {
            case markdown(String)
            case code(String)
        }
        let kind: Kind
    }

    private func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var current: [String] = []
        var inCode = false

        func flushMarkdown() {
            let s = current.joined(separator: "\n")
            current.removeAll(keepingCapacity: true)
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            blocks.append(MarkdownBlock(kind: .markdown(s)))
        }

        func flushCode() {
            let s = current.joined(separator: "\n")
            current.removeAll(keepingCapacity: true)
            blocks.append(MarkdownBlock(kind: .code(s)))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushMarkdown()
                    inCode = true
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
            blocks.append(MarkdownBlock(kind: .markdown(text)))
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
