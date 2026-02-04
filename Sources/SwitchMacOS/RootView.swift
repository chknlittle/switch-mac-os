import AppKit
import Foundation
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
    @ObservedObject var chatStore: ChatStore
    @StateObject private var drafts = ComposerDraftStore()
    @State private var pendingImage: PendingImageAttachment? = nil

    var body: some View {
        HSplitView {
            SidebarList(directory: directory, xmpp: xmpp, chatStore: chatStore)
                .frame(minWidth: 240)

            ChatPane(
                title: chatTitle,
                threadJid: directory.chatTarget?.jid,
                messages: messagesForActiveChat(),
                xmpp: xmpp,
                composerText: composerBinding,
                pendingImage: $pendingImage,
                onSend: {
                    guard let jid = directory.chatTarget?.jid else { return }
                    let raw = drafts.draft(for: jid)
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let pending = pendingImage {
                        directory.sendImageAttachment(
                            data: pending.data,
                            filename: pending.filename,
                            mime: pending.mime,
                            caption: trimmed.isEmpty ? nil : trimmed
                        )
                        pendingImage = nil
                        drafts.setDraft("", for: jid)
                        return
                    }
                    guard !trimmed.isEmpty else { return }
                    directory.sendChat(body: trimmed)
                    drafts.setDraft("", for: jid)
                },
                isEnabled: directory.chatTarget != nil,
                isTyping: isChatTargetTyping
            )
        }
        .onAppear {
            chatStore.setActiveThread(directory.chatTarget?.jid)
        }
        .onChange(of: directory.chatTarget?.jid) { newValue in
            chatStore.setActiveThread(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            drafts.flush()
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
            if let item = directory.dispatchers.first(where: { $0.jid == jid }) {
                return "Dispatcher: \(item.name)"
            }
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

    private var composerBinding: Binding<String> {
        Binding(
            get: {
                guard let jid = directory.chatTarget?.jid else { return "" }
                return drafts.draft(for: jid)
            },
            set: { newValue in
                guard let jid = directory.chatTarget?.jid else { return }
                drafts.setDraft(newValue, for: jid)
            }
        )
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
                                        // directory.individuals is sorted by recency (most recent first);
                                        // show the oldest at the top so the most recent sits at the bottom.
                                        ForEach(Array(directory.individuals.reversed())) { item in
                                            SidebarRow(
                                                title: item.name,
                                                subtitle: nil,
                                                showAvatar: false,
                                                avatarData: nil,
                                                isSelected: directory.selectedSessionJid == item.jid,
                                                isComposing: xmpp.composingJids.contains(item.jid),
                                                unreadCount: chatStore.unreadCount(for: item.jid),
                                                onCancel: {
                                                    xmpp.sendMessage(to: item.jid, body: "/cancel")
                                                }
                                            ) {
                                                directory.selectIndividual(item)
                                            }
                                            .id(item.jid)
                                            .padding(.horizontal, 10)
                                        }
                                    } else if !directory.isLoadingIndividuals {
                                        SidebarPlaceholderRow(
                                            title: "No sessions",
                                            subtitle: "This dispatcher has no active sessions",
                                            isLoading: false
                                        )
                                        .padding(.horizontal, 10)
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

                    HStack(spacing: 6) {
                        if directory.isLoadingIndividuals {
                            ProgressView()
                                .scaleEffect(0.55)
                        }
                        Text("\(directory.individuals.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(Capsule(style: .continuous))
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    SidebarSectionHeader(title: "Dispatchers", count: directory.dispatchers.count, detail: selectedDispatcherName)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            if directory.dispatchers.isEmpty {
                                Text("Loading dispatchers...")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(directory.dispatchers) { item in
                                    let isSelected = directory.selectedDispatcherJid == item.jid
                                    let isComposing = directory.dispatchersWithComposingSessions.contains(item.jid)
                                    let unreadCount = directory.unreadCountForDispatcher(item.jid, unreadByThread: chatStore.unreadByThread)

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
                        .padding(.bottom, 10)
                    }
                }
            }
        }
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
                    .foregroundStyle(.secondary)
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
                    .background(Color.secondary.opacity(0.10))
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
    let showAvatar: Bool
    let avatarData: Data?
    let isSelected: Bool
    let isComposing: Bool
    let unreadCount: Int
    let onCancel: (() -> Void)?
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showAvatar {
                AvatarCircle(imageData: avatarData, fallbackText: title)
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
            if unreadCount > 0 {
                UnreadBadge(count: unreadCount)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
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
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.22), Color.secondary.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

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
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 1)
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
            .background(Color.secondary.opacity(0.14))
            .clipShape(Capsule())
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

private struct ChatPane: View {
    let title: String
    let threadJid: String?
    let messages: [ChatMessage]
    let xmpp: XMPPService
    @Binding var composerText: String
    @Binding var pendingImage: PendingImageAttachment?
    let onSend: () -> Void
    let isEnabled: Bool
    let isTyping: Bool

    private let bottomAnchorId: String = "__bottom__"
    private let composerMinHeight: CGFloat = 28
    private let composerMaxHeight: CGFloat = 160
    @State private var composerHeight: CGFloat = 28
    @State private var scrollTask: Task<Void, Never>? = nil
    @State private var isDropTarget: Bool = false

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
                                MessageRow(msg: msg, xmpp: xmpp)
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

            Divider()

            VStack(spacing: 8) {
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
        .onChange(of: composerText) { newValue in
            if newValue.isEmpty {
                composerHeight = composerMinHeight
            }
        }
        .onChange(of: threadJid) { _ in
            pendingImage = nil
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

    private struct MessageRow: View {
        let msg: ChatMessage
        let xmpp: XMPPService

        private var isToolMessage: Bool {
            msg.meta?.isToolRelated ?? false
        }

        var body: some View {
            HStack {
                if msg.direction == .outgoing {
                    Spacer(minLength: 32)
                }

                VStack(alignment: msg.direction == .incoming ? .leading : .trailing, spacing: 2) {
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
            let formatter = DateFormatter()

            if calendar.isDateInToday(date) {
                formatter.dateFormat = "h:mm a"
                return formatter.string(from: date)
            } else if calendar.isDateInYesterday(date) {
                formatter.dateFormat = "h:mm a"
                return "Yesterday \(formatter.string(from: date))"
            } else if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
                formatter.dateFormat = "EEEE h:mm a"
                return formatter.string(from: date)
            } else {
                formatter.dateFormat = "MMM d, h:mm a"
                return formatter.string(from: date)
            }
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
                    MarkdownMessage(content: caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(bubbleColor)
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
            return u.scheme == "http" || u.scheme == "https" || u.scheme == "file"
        }

        private var bubbleColor: Color {
            switch direction {
            case .incoming:
                return Color.secondary.opacity(0.12)
            case .outgoing:
                return Color.accentColor.opacity(0.18)
            }
        }

        private func openAttachment(_ att: SwitchAttachment) {
            if let s = att.publicUrl, let u = URL(string: s) {
                NSWorkspace.shared.open(u)
                return
            }
            if let p = att.localPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: p))
                return
            }
        }

        private struct AttachmentThumbnail: View {
            let att: SwitchAttachment

            var body: some View {
                Button(action: { open() }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.10))

                        if let url = bestUrl() {
                            if url.isFileURL {
                                if let img = NSImage(contentsOf: url) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    placeholder
                                }
                            } else {
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

            private func bestUrl() -> URL? {
                if let s = att.publicUrl, let u = URL(string: s) { return u }
                if let p = att.localPath { return URL(fileURLWithPath: p) }
                return nil
            }

            private func open() {
                if let url = bestUrl() {
                    NSWorkspace.shared.open(url)
                }
            }
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

private struct MarkdownMessage: View {
    let content: String

    var body: some View {
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
            case .code(let s, _):
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
