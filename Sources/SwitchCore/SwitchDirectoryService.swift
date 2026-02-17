import Combine
import Foundation
import Martin

@MainActor
public final class SwitchDirectoryService: ObservableObject {
    @Published public private(set) var dispatchers: [DirectoryItem] = []
    @Published public private(set) var individuals: [DirectoryItem] = []

    // UI state: used to distinguish "empty" from "still loading".
    @Published public private(set) var isLoadingIndividuals: Bool = false
    @Published public private(set) var individualsLoadedOnce: Bool = false

    @Published public private(set) var selectedDispatcherJid: String? = nil
    @Published public private(set) var selectedSessionJid: String? = nil
    @Published public private(set) var chatTarget: ChatTarget? = nil

    /// Tracks which sessions belong to which dispatcher (dispatcher JID -> session JIDs)
    private var dispatcherToSessions: [String: Set<String>] = [:]
    private var sessionToDispatcher: [String: String] = [:]

    /// Returns set of dispatcher JIDs that have at least one composing session
    public var dispatchersWithComposingSessions: Set<String> {
        var result: Set<String> = []
        for sessionJid in xmpp.composingJids {
            if let dispatcherJid = sessionToDispatcher[sessionJid] {
                result.insert(dispatcherJid)
            }
        }
        return result
    }

    public func unreadCountForDispatcher(_ dispatcherJid: String, unreadByThread: [String: Int]) -> Int {
        var total = unreadByThread[dispatcherJid] ?? 0
        for sessionJid in dispatcherToSessions[dispatcherJid] ?? [] {
            total += unreadByThread[sessionJid] ?? 0
        }
        return total
    }

    private let xmpp: XMPPService
    private let directoryJid: JID
    private let directoryBareJid: BareJID
    private let pubSubBareJid: BareJID?
    private let nodes: SwitchDirectoryNodes
    private let convenienceDispatchers: [DirectoryItem]
    private var cancellables: Set<AnyCancellable> = []
    private var subscribedNodes: Set<String> = []
    private var pendingSubscriptions: Set<String> = []
    private var lastSelectedIndividualJid: String? = nil
    private var individualsRefreshToken: UUID? = nil
    private var awaitingNewSession = false
    private var awaitNewSessionTimeoutWorkItem: DispatchWorkItem? = nil
    private var knownIndividualJids: Set<String> = []
    private var dispatchersLoaded = false

    // Sorting can cause visible list "jitter" while history loads; debounce and
    // briefly suppress resorting during initial loads.
    private var resortWorkItem: DispatchWorkItem? = nil
    private var resortAfterSuppressionWorkItem: DispatchWorkItem? = nil
    private var suppressResortUntil: Date = .distantPast

    // Cache sessions per dispatcher so switching back is instant.
    private var sessionsByDispatcher: [String: [DirectoryItem]] = [:]

    // Remember the last selected session per dispatcher.
    private var selectedSessionByDispatcher: [String: String] = [:]

    // Track known sessions per dispatcher to avoid repeated expensive work on unchanged lists.
    private var knownSessionJidsByDispatcher: [String: Set<String>] = [:]

    // Only restore remembered selection once per explicit dispatcher switch.
    private var pendingRestoreDispatcherJid: String? = nil

    // Dispatchers that are "direct" (no sessions, e.g. external bridges).
    private var directDispatchers: Set<String> = []

    private let historyPrefetchLimit: Int
    private let recencyProbeLimit: Int

    public init(
        xmpp: XMPPService,
        directoryJid: String,
        pubSubJid: String?,
        convenienceDispatchers: [DirectoryItem] = [],
        nodes: SwitchDirectoryNodes = SwitchDirectoryNodes()
    ) {
        self.xmpp = xmpp
        // IMPORTANT: ejabberd answers disco#items for bare user JIDs itself (PEP).
        // We must address the directory bot via a full JID resource so the IQ
        // reaches the connected client.
        self.directoryJid = JID(directoryJid)
        self.directoryBareJid = BareJID(directoryJid)
        // PubSub service is often a domain JID (e.g. pubsub.example.com).
        self.pubSubBareJid = pubSubJid.map { JID($0).bareJid }
        self.nodes = nodes
        self.convenienceDispatchers = convenienceDispatchers
        self.historyPrefetchLimit = Self.envInt("SWITCH_PREFETCH_HISTORY_THREADS", defaultValue: 0, min: 0, max: 50)
        self.recencyProbeLimit = Self.envInt("SWITCH_RECENCY_PROBE_THREADS", defaultValue: 5000, min: 0, max: 5000)
        bindPubSubRefresh()
    }

    public func refreshAll() {
        if !dispatchersLoaded {
            refreshDispatchers()
        }
        if let dispatcher = selectedDispatcherJid, !directDispatchers.contains(dispatcher) {
            refreshSessionsForDispatcher(dispatcherJid: dispatcher)
        } else {
            individuals = []
            isLoadingIndividuals = false
            individualsLoadedOnce = directDispatchers.contains(selectedDispatcherJid ?? "")
        }
    }

    public func selectDispatcher(_ item: DirectoryItem) {
        // Clicking the currently-selected dispatcher should not re-fetch sessions.
        // Treat it as a focus action that switches the chat target back to the dispatcher.
        if selectedDispatcherJid == item.jid {
            selectedSessionJid = nil
            chatTarget = .dispatcher(item.jid)
            lastSelectedIndividualJid = nil
            clearAwaitingNewSession()
            xmpp.ensureHistoryLoaded(with: item.jid)
            return
        }

        selectedDispatcherJid = item.jid
        selectedSessionJid = nil
        chatTarget = .dispatcher(item.jid)
        lastSelectedIndividualJid = nil
        clearAwaitingNewSession()

        // Direct dispatchers (e.g. Acorn) have no sessions — skip loading entirely.
        if item.isDirect {
            individuals = []
            isLoadingIndividuals = false
            individualsLoadedOnce = true
            directDispatchers.insert(item.jid)
            xmpp.ensureHistoryLoaded(with: item.jid)
            return
        }

        let rememberedSessionJid = selectedSessionByDispatcher[item.jid]
        pendingRestoreDispatcherJid = rememberedSessionJid == nil ? nil : item.jid

        // Use cached sessions if we have them; still refresh in the background.
        if let cached = sessionsByDispatcher[item.jid], !cached.isEmpty {
            individuals = sortByRecency(cached)
            dispatcherToSessions[item.jid] = Set(cached.map { $0.jid })
            isLoadingIndividuals = false
            individualsLoadedOnce = true
            restoreRememberedSession(for: item.jid, rememberedSessionJid: rememberedSessionJid)
            pendingRestoreDispatcherJid = nil
        } else {
            individuals = []
            isLoadingIndividuals = true
            individualsLoadedOnce = false
        }

        suppressResortUntil = Date().addingTimeInterval(1.5)
        xmpp.ensureHistoryLoaded(with: item.jid)

        // Subscribe to this dispatcher's sessions node and fetch.
        let sessionsNode = nodes.sessions(item.jid)
        ensureSubscribed(to: sessionsNode)
        refreshSessionsForDispatcher(dispatcherJid: item.jid)
    }

    public func selectIndividual(_ item: DirectoryItem) {
        clearAwaitingNewSession()
        selectedSessionJid = item.jid
        chatTarget = .individual(item.jid)
        lastSelectedIndividualJid = item.jid
        if let dispatcherJid = selectedDispatcherJid {
            selectedSessionByDispatcher[dispatcherJid] = item.jid
        }
        xmpp.ensureHistoryLoaded(with: item.jid)
    }

    /// Select the next session in display order (visually downward).
    public func selectNextSession() {
        let displayOrder = individuals.reversed() as [DirectoryItem]
        guard !displayOrder.isEmpty else { return }
        guard let currentJid = selectedSessionJid,
              let currentIndex = displayOrder.firstIndex(where: { $0.jid == currentJid }) else {
            // Nothing selected — select the last (bottom-most, most recent).
            selectIndividual(displayOrder[displayOrder.count - 1])
            return
        }
        let nextIndex = currentIndex + 1
        guard nextIndex < displayOrder.count else { return }
        selectIndividual(displayOrder[nextIndex])
    }

    /// Select the previous session in display order (visually upward).
    public func selectPreviousSession() {
        let displayOrder = individuals.reversed() as [DirectoryItem]
        guard !displayOrder.isEmpty else { return }
        guard let currentJid = selectedSessionJid,
              let currentIndex = displayOrder.firstIndex(where: { $0.jid == currentJid }) else {
            // Nothing selected — select the last (bottom-most, most recent).
            selectIndividual(displayOrder[displayOrder.count - 1])
            return
        }
        let prevIndex = currentIndex - 1
        guard prevIndex >= 0 else {
            // Already at the top — deselect and go back to dispatcher.
            if let dispatcherJid = selectedDispatcherJid {
                selectedSessionJid = nil
                chatTarget = .dispatcher(dispatcherJid)
                lastSelectedIndividualJid = nil
            }
            return
        }
        selectIndividual(displayOrder[prevIndex])
    }

    /// Resume an old session by sending a pickup message to the current dispatcher.
    public func resumeSession(_ item: DirectoryItem) {
        guard let dispatcherJid = selectedDispatcherJid else { return }

        // Switch chat target to the dispatcher so the message goes there.
        selectedSessionJid = nil
        chatTarget = .dispatcher(dispatcherJid)
        lastSelectedIndividualJid = nil

        let body = "pick up where the '\(item.name)' switch session left off"
        xmpp.sendMessage(to: dispatcherJid, body: body)

        // Poll for the new session to appear.
        knownIndividualJids = Set(individuals.map { $0.jid })
        beginAwaitingNewSession(dispatcherJid: dispatcherJid)
    }

    public func sendChat(body: String) {
        guard let target = chatTarget else { return }
        let jid = target.jid

        switch target {
        case .subagent:
            let taskId = UUID().uuidString
            let parent = lastSelectedIndividualJid ?? xmpp.client.userBareJid.stringValue
            xmpp.sendSubagentWork(to: jid, taskId: taskId, parentJid: parent, body: body)
        case .dispatcher, .individual:
            xmpp.sendMessage(to: jid, body: body)
        }

        if case .dispatcher(let dispatcherJid) = target {
            if selectedDispatcherJid == dispatcherJid, !directDispatchers.contains(dispatcherJid) {
                beginAwaitingNewSession(dispatcherJid: dispatcherJid)
            }
        }
    }

    public func sendImageAttachment(data: Data, filename: String, mime: String, caption: String?) {
        guard let target = chatTarget else { return }
        let jid = target.jid

        switch target {
        case .subagent:
            return
        case .dispatcher, .individual:
            xmpp.sendImageAttachment(to: jid, data: data, filename: filename, mime: mime, caption: caption)
        }

        if case .dispatcher(let dispatcherJid) = target {
            if selectedDispatcherJid == dispatcherJid, !directDispatchers.contains(dispatcherJid) {
                beginAwaitingNewSession(dispatcherJid: dispatcherJid)
            }
        }
    }

    /// Jump to the session that has been waiting for a reply the longest.
    /// Returns true when a target session was found and selected.
    @discardableResult
    public func focusOldestWaitingSession() -> Bool {
        let unread = xmpp.chatStore.unreadByThread
        let dispatcherJids = Set(dispatchers.map { $0.jid })

        let waitingCandidates: [(jid: String, waitingSince: Date, dispatcherJid: String?)] = unread.compactMap { threadJid, count in
            guard count > 0 else { return nil }

            // This action targets sessions, not dispatcher chats.
            if dispatcherJids.contains(threadJid) {
                return nil
            }

            let waitingSince = oldestUnreadTimestamp(for: threadJid, unreadCount: count)
                ?? xmpp.chatStore.lastActivityByThread[threadJid]
                ?? Date.distantFuture
            return (threadJid, waitingSince, dispatcherForSession(threadJid))
        }

        if let target = waitingCandidates.min(by: { a, b in
            if a.waitingSince != b.waitingSince {
                return a.waitingSince < b.waitingSince
            }
            return a.jid.localizedStandardCompare(b.jid) == .orderedAscending
        }) {
            selectSessionThread(jid: target.jid, dispatcherJid: target.dispatcherJid)
            return true
        }

        // Fallback: if nothing is currently unread, still jump to the most
        // recent known session so the shortcut always does something useful.
        if let fallback = mostRecentKnownSession(excludingDispatchers: dispatcherJids) {
            selectSessionThread(jid: fallback.jid, dispatcherJid: fallback.dispatcherJid)
            return true
        }

        return false
    }

    public func messagesForActiveChat() -> [ChatMessage] {
        guard let target = chatTarget else { return [] }
        return xmpp.chatStore.messages(for: target.jid)
    }

    private func oldestUnreadTimestamp(for threadJid: String, unreadCount: Int) -> Date? {
        guard unreadCount > 0 else { return nil }
        let messages = xmpp.chatStore.messages(for: threadJid)
        guard !messages.isEmpty else { return nil }

        var remaining = unreadCount
        for msg in messages.reversed() where msg.direction == .incoming {
            remaining -= 1
            if remaining <= 0 {
                return msg.timestamp
            }
        }

        return messages.last(where: { $0.direction == .incoming })?.timestamp
    }

    private func dispatcherForSession(_ sessionJid: String) -> String? {
        if let selected = selectedDispatcherJid,
           individuals.contains(where: { $0.jid == sessionJid }) {
            return selected
        }

        if let fromLiveMap = dispatcherToSessions.first(where: { $0.value.contains(sessionJid) })?.key {
            return fromLiveMap
        }

        if let fromCache = sessionsByDispatcher.first(where: { _, items in
            items.contains(where: { $0.jid == sessionJid })
        })?.key {
            return fromCache
        }

        return nil
    }

    private func selectSessionThread(jid sessionJid: String, dispatcherJid: String?) {
        if let dispatcherJid,
           selectedDispatcherJid != dispatcherJid,
           let dispatcherItem = dispatchers.first(where: { $0.jid == dispatcherJid }) {
            selectDispatcher(dispatcherItem)
        }

        let selectedDispatcher = dispatcherJid ?? selectedDispatcherJid
        let knownItem = individuals.first(where: { $0.jid == sessionJid })
            ?? (selectedDispatcher.flatMap { sessionsByDispatcher[$0] }?.first(where: { $0.jid == sessionJid }))

        if let knownItem {
            selectIndividual(knownItem)
            return
        }

        // Fallback when we only know the thread JID from unread counters.
        selectIndividual(DirectoryItem(jid: sessionJid, name: nil))
    }

    private func mostRecentKnownSession(excludingDispatchers dispatcherJids: Set<String>) -> (jid: String, dispatcherJid: String?)? {
        var sessionJids: Set<String> = Set(individuals.map(\.jid))
        sessionJids.formUnion(dispatcherToSessions.values.flatMap { $0 })
        sessionJids.formUnion(sessionsByDispatcher.values.flatMap { $0.map(\.jid) })

        sessionJids = sessionJids.subtracting(dispatcherJids)
        guard !sessionJids.isEmpty else { return nil }

        let activity = xmpp.chatStore.lastActivityByThread
        let bestJid = sessionJids.max { a, b in
            let aTime = activity[a] ?? Date.distantPast
            let bTime = activity[b] ?? Date.distantPast
            if aTime != bTime {
                return aTime < bTime
            }
            return a.localizedStandardCompare(b) == .orderedAscending
        }

        guard let bestJid else { return nil }
        return (bestJid, dispatcherForSession(bestJid))
    }

    private func beginAwaitingNewSession(dispatcherJid: String) {
        knownIndividualJids = Set(individuals.map { $0.jid })
        awaitingNewSession = true

        awaitNewSessionTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.awaitingNewSession else { return }
                guard self.selectedDispatcherJid == dispatcherJid else { return }
                guard case .dispatcher(let targetDispatcherJid) = self.chatTarget, targetDispatcherJid == dispatcherJid else { return }
                self.clearAwaitingNewSession()
            }
        }
        awaitNewSessionTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: work)
    }

    private func autoSelectNewSessionIfNeeded() {
        guard awaitingNewSession else { return }
        guard case .dispatcher = chatTarget else {
            clearAwaitingNewSession()
            return
        }
        let currentJids = Set(individuals.map { $0.jid })
        let newJids = currentJids.subtracting(knownIndividualJids)
        guard let newItem = individuals.first(where: { newJids.contains($0.jid) }) else {
            return
        }
        clearAwaitingNewSession()
        selectIndividual(newItem)
    }

    private func clearAwaitingNewSession() {
        awaitingNewSession = false
        awaitNewSessionTimeoutWorkItem?.cancel()
        awaitNewSessionTimeoutWorkItem = nil
    }

    // MARK: - Dispatchers (fetched once, cached permanently)

    private func refreshDispatchers() {
        let node = nodes.dispatchers
        ensureSubscribed(to: node)
        queryItems(node: node) { [weak self] items in
            guard let self else { return }
            self.dispatchers = self.mergedDispatchersWithConvenienceContacts(items)
            self.dispatchersLoaded = true

            // If nothing is selected yet, pick the first dispatcher and load sessions.
            if self.selectedDispatcherJid == nil, let first = self.dispatchers.first {
                self.selectDispatcher(first)
            }
        }
    }

    private func mergedDispatchersWithConvenienceContacts(_ serverItems: [DirectoryItem]) -> [DirectoryItem] {
        var merged = serverItems
        let existing = Set(serverItems.map { $0.jid })
        for item in convenienceDispatchers where !existing.contains(item.jid) {
            merged.append(item)
            directDispatchers.insert(item.jid)
        }
        return merged
    }

    // MARK: - Sessions (direct query, no groups indirection)

    private func refreshSessionsForDispatcher(dispatcherJid: String) {
        let token = UUID()
        individualsRefreshToken = token

        if selectedDispatcherJid == dispatcherJid, individuals.isEmpty {
            isLoadingIndividuals = true
        }

        let node = nodes.sessions(dispatcherJid)
        ensureSubscribed(to: node)
        queryItems(node: node) { [weak self] items in
            guard let self else { return }
            guard self.individualsRefreshToken == token else { return }
            guard self.selectedDispatcherJid == dispatcherJid else { return }
            self.applySessionsList(items, forDispatcher: dispatcherJid)
        }
    }

    /// Apply a session list (from disco query or fat pubsub notification).
    private func applySessionsList(_ items: [DirectoryItem], forDispatcher dispatcherJid: String) {
        let sorted = sortByRecency(items)
        sessionsByDispatcher[dispatcherJid] = sorted
        let visibleJids = Set(sorted.map { $0.jid })
        dispatcherToSessions[dispatcherJid] = visibleJids

        let previousJids = knownSessionJidsByDispatcher[dispatcherJid] ?? []
        knownSessionJidsByDispatcher[dispatcherJid] = visibleJids
        let newlySeenJids = visibleJids.subtracting(previousJids)

        for oldJid in previousJids where !visibleJids.contains(oldJid) {
            if sessionToDispatcher[oldJid] == dispatcherJid {
                sessionToDispatcher.removeValue(forKey: oldJid)
            }
        }
        for jid in visibleJids {
            sessionToDispatcher[jid] = dispatcherJid
        }

        if let rememberedJid = selectedSessionByDispatcher[dispatcherJid], !visibleJids.contains(rememberedJid) {
            selectedSessionByDispatcher[dispatcherJid] = nil
        }

        if selectedDispatcherJid == dispatcherJid {
            let didChangeIndividuals = individuals != sorted
            if didChangeIndividuals {
                individuals = sorted
            }
            if pendingRestoreDispatcherJid == dispatcherJid {
                restoreRememberedSession(for: dispatcherJid)
                pendingRestoreDispatcherJid = nil
            }
            if didChangeIndividuals {
                suppressResortUntil = Date().addingTimeInterval(1.5)
                scheduleResortAfterSuppression()
            }
            let newItems = sorted.filter { newlySeenJids.contains($0.jid) }
            probeRecencyForSessions(newItems)
            loadHistoryForSessions(newItems)
            autoSelectNewSessionIfNeeded()
            isLoadingIndividuals = false
            individualsLoadedOnce = true
        }
    }

    // MARK: - Disco query

    private func queryItems(node: String, assign: @escaping @MainActor ([DirectoryItem]) -> Void) {
        let disco = xmpp.disco()
        disco.getItems(for: directoryJid, node: node) { result in
            Task { @MainActor in
                switch result {
                case .success(let items):
                    let mapped = items.items.map { item -> DirectoryItem in
                        // Node tokens are colon-delimited and may include:
                        // - dispatcher sort index (e.g. "0")
                        // - "direct" for no-session dispatchers
                        // - "closed" for historical sessions
                        // - "group"/"muc"/"room" for shared sessions
                        let nodeTags = self.nodeTagSet(item.node)
                        let isDirect = nodeTags.contains("direct")
                        let isClosed = nodeTags.contains("closed")
                        let isGroup = nodeTags.contains("group") || nodeTags.contains("muc") || nodeTags.contains("room") || self.isLikelyGroupJid(item.jid.bareJid.stringValue)
                        let sortOrder = self.parseSortOrder(item.node)

                        return DirectoryItem(
                            jid: item.jid.bareJid.stringValue,
                            name: item.name,
                            isDirect: isDirect,
                            sortOrder: sortOrder,
                            isClosed: isClosed,
                            isGroup: isGroup
                        )
                    }.sorted { $0.sortOrder < $1.sortOrder }
                    assign(mapped)
                case .failure:
                    assign([])
                }
            }
        }
    }

    private func restoreRememberedSession(for dispatcherJid: String, rememberedSessionJid: String? = nil) {
        guard selectedDispatcherJid == dispatcherJid else { return }

        if let current = selectedSessionJid, individuals.contains(where: { $0.jid == current }) {
            return
        }

        let remembered = rememberedSessionJid ?? selectedSessionByDispatcher[dispatcherJid]
        guard let remembered,
              let rememberedItem = individuals.first(where: { $0.jid == remembered }) else {
            selectedSessionJid = nil
            chatTarget = .dispatcher(dispatcherJid)
            lastSelectedIndividualJid = nil
            return
        }

        selectedSessionJid = rememberedItem.jid
        chatTarget = .individual(rememberedItem.jid)
        lastSelectedIndividualJid = rememberedItem.jid
        xmpp.ensureHistoryLoaded(with: rememberedItem.jid)
    }

    // MARK: - PubSub

    private func ensureSubscribed(to node: String) {
        guard !subscribedNodes.contains(node) else { return }
        guard !pendingSubscriptions.contains(node) else { return }
        pendingSubscriptions.insert(node)

        let subscriber = xmpp.client.boundJid ?? JID(xmpp.client.userBareJid)
        let service = pubSubBareJid ?? directoryBareJid
        xmpp.pubsub().subscribe(at: service, to: node, subscriber: subscriber, with: nil as JabberDataElement?, completionHandler: { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingSubscriptions.remove(node)
                self.subscribedNodes.insert(node)
            }
        })
    }

    private func bindPubSubRefresh() {
        xmpp.pubSubItemsEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                guard self.subscribedNodes.contains(notification.node) else { return }

                let node = notification.node

                // Try to extract a fat sessions payload from the notification.
                if node.hasPrefix("sessions:") {
                    if let items = self.parseSessionsPayload(notification) {
                        let dispatcherJid = String(node.dropFirst("sessions:".count))
                        self.applySessionsList(items, forDispatcher: dispatcherJid)
                        return
                    }
                    // Payload missing or unparseable — fall back to disco query.
                    let dispatcherJid = String(node.dropFirst("sessions:".count))
                    if self.selectedDispatcherJid == dispatcherJid {
                        self.refreshSessionsForDispatcher(dispatcherJid: dispatcherJid)
                    }
                    return
                }

                // Legacy individuals: node — refresh sessions for the active dispatcher.
                if node.hasPrefix("individuals:") {
                    if let dispatcher = self.selectedDispatcherJid {
                        self.refreshSessionsForDispatcher(dispatcherJid: dispatcher)
                    }
                    return
                }

                // Dispatchers node changed (rare — config change on server).
                if node == self.nodes.dispatchers {
                    self.dispatchersLoaded = false
                    self.refreshDispatchers()
                    return
                }
            }
            .store(in: &cancellables)

        // Re-sort sessions and dispatchers when new messages arrive
        // Re-sort only when activity changed for a currently-visible session.
        xmpp.chatStore.activityUpdatedThread
            .receive(on: DispatchQueue.main)
            .sink { [weak self] threadJid in
                guard let self else { return }
                guard self.individuals.contains(where: { $0.jid == threadJid }) else { return }
                self.scheduleResort()
            }
            .store(in: &cancellables)
    }

    /// Parse a fat pubsub notification: <switch event="sessions"><session jid="..." name="..."/>...</switch>
    private func parseSessionsPayload(_ notification: PubSubModule.ItemNotification) -> [DirectoryItem]? {
        guard case .published(let item) = notification.action else { return nil }
        guard let payload = item.payload else { return nil }

        guard payload.attribute("event") == "sessions" else { return nil }

        var items: [DirectoryItem] = []
        for child in payload.children where child.name == "session" {
            guard let jid = child.attribute("jid") else { continue }
            let name = child.attribute("name")
            let isClosed = child.attribute("status") == "closed"
            let isGroup = payloadSessionIsGroup(child, jid: jid)
            items.append(DirectoryItem(jid: jid, name: name, isClosed: isClosed, isGroup: isGroup))
        }
        return items
    }

    private func payloadSessionIsGroup(_ node: Element, jid: String) -> Bool {
        let kind = node.attribute("kind")?.lowercased()
        let type = node.attribute("type")?.lowercased()
        let chat = node.attribute("chat")?.lowercased()
        let hasRoomAttr = !(node.attribute("room") ?? "").isEmpty
        return kind == "group"
            || type == "group"
            || type == "groupchat"
            || chat == "group"
            || boolAttribute(node.attribute("group"))
            || hasRoomAttr
            || isLikelyGroupJid(jid)
    }

    private func boolAttribute(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !normalized.isEmpty else {
            return false
        }
        return normalized == "1" || normalized == "true" || normalized == "yes"
    }

    private func parseSortOrder(_ node: String?) -> Int {
        guard let node, !node.isEmpty else { return Int.max }
        for token in node.split(separator: ":") {
            if let value = Int(token) {
                return value
            }
        }
        return Int.max
    }

    private func nodeTagSet(_ node: String?) -> Set<String> {
        guard let node, !node.isEmpty else { return [] }
        var tags: Set<String> = []
        for token in node.split(separator: ":") {
            if Int(token) != nil { continue }
            tags.insert(String(token).lowercased())
        }
        return tags
    }

    private func isLikelyGroupJid(_ jid: String) -> Bool {
        let bare = jid.split(separator: "/", maxSplits: 1).first.map(String.init) ?? jid
        let domain = bare.split(separator: "@", maxSplits: 1).last.map(String.init)?.lowercased() ?? ""
        guard !domain.isEmpty else { return false }
        return domain.hasPrefix("conference.")
            || domain.contains(".conference.")
            || domain.hasPrefix("muc.")
            || domain.contains(".muc.")
    }

    private static func envInt(_ key: String, defaultValue: Int, min: Int, max: Int) -> Int {
        let raw = ProcessInfo.processInfo.environment[key] ?? String(defaultValue)
        let parsed = Int(raw) ?? defaultValue
        return Swift.max(min, Swift.min(parsed, max))
    }

    // MARK: - Sorting

    private func scheduleResort() {
        resortWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.isLoadingIndividuals { return }
                if self.xmpp.isHistoryWarmup { return }
                if Date() < self.suppressResortUntil { return }
                self.resortIndividualsByRecency()
            }
        }
        resortWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func scheduleResortAfterSuppression() {
        resortAfterSuppressionWorkItem?.cancel()
        let delay = max(0.05, suppressResortUntil.timeIntervalSinceNow + 0.05)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.resortAfterSuppressionWorkItem = nil
                if self.isLoadingIndividuals { return }
                if self.xmpp.isHistoryWarmup { return }
                self.resortIndividualsByRecency()
            }
        }
        resortAfterSuppressionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resortIndividualsByRecency() {
        guard !individuals.isEmpty else { return }
        let sorted = sortByRecency(individuals)
        if sorted != individuals {
            individuals = sorted
        }
    }

    private func loadHistoryForSessions(_ items: [DirectoryItem]) {
        guard historyPrefetchLimit > 0 else { return }
        guard !items.isEmpty else { return }

        for item in items.prefix(historyPrefetchLimit) {
            xmpp.ensureHistoryLoaded(with: item.jid)
        }
    }

    private func probeRecencyForSessions(_ items: [DirectoryItem]) {
        guard recencyProbeLimit > 0 else { return }
        guard !items.isEmpty else { return }

        for item in items.filter({ !$0.isClosed }).prefix(recencyProbeLimit) {
            xmpp.ensureRecencyProbed(with: item.jid)
        }
    }

    private func sortByRecency(_ items: [DirectoryItem]) -> [DirectoryItem] {
        // Active sessions sorted by recency, closed sessions keep server order at the end.
        let active = items.filter { !$0.isClosed }
        let closed = items.filter { $0.isClosed }
        let chatStore = xmpp.chatStore
        var recencyByJid: [String: Date] = [:]
        recencyByJid.reserveCapacity(active.count)
        for item in active {
            recencyByJid[item.jid] = chatStore.lastActivityByThread[item.jid] ?? .distantPast
        }
        let sortedActive = active.sorted { a, b in
            let aTime = recencyByJid[a.jid] ?? .distantPast
            let bTime = recencyByJid[b.jid] ?? .distantPast
            if aTime != bTime {
                return aTime > bTime
            }
            if a.name != b.name {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return a.jid.localizedStandardCompare(b.jid) == .orderedAscending
        }
        return sortedActive + closed
    }

}
