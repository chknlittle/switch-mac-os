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

    /// Returns set of dispatcher JIDs that have at least one composing session
    public var dispatchersWithComposingSessions: Set<String> {
        var result: Set<String> = []
        let composing = xmpp.composingJids
        for (dispatcherJid, sessionJids) in dispatcherToSessions {
            if !sessionJids.isDisjoint(with: composing) {
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
    private var cancellables: Set<AnyCancellable> = []
    private var subscribedNodes: Set<String> = []
    private var pendingSubscriptions: Set<String> = []
    private var lastSelectedIndividualJid: String? = nil
    private var individualsRefreshToken: UUID? = nil
    private var awaitingNewSession = false
    private var knownIndividualJids: Set<String> = []
    private var dispatchersLoaded = false

    // Sorting can cause visible list "jitter" while history loads; debounce and
    // briefly suppress resorting during initial loads.
    private var resortWorkItem: DispatchWorkItem? = nil
    private var resortAfterSuppressionWorkItem: DispatchWorkItem? = nil
    private var suppressResortUntil: Date = .distantPast

    // Cache sessions per dispatcher so switching back is instant.
    private var sessionsByDispatcher: [String: [DirectoryItem]] = [:]

    // Dispatchers that are "direct" (no sessions, e.g. external bridges).
    private var directDispatchers: Set<String> = []

    public init(
        xmpp: XMPPService,
        directoryJid: String,
        pubSubJid: String?,
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
            awaitingNewSession = false
            xmpp.ensureHistoryLoaded(with: item.jid)
            return
        }

        selectedDispatcherJid = item.jid
        selectedSessionJid = nil
        chatTarget = .dispatcher(item.jid)
        lastSelectedIndividualJid = nil
        awaitingNewSession = false

        // Direct dispatchers (e.g. Acorn) have no sessions — skip loading entirely.
        if item.isDirect {
            individuals = []
            isLoadingIndividuals = false
            individualsLoadedOnce = true
            directDispatchers.insert(item.jid)
            xmpp.ensureHistoryLoaded(with: item.jid)
            return
        }

        // Use cached sessions if we have them; still refresh in the background.
        if let cached = sessionsByDispatcher[item.jid], !cached.isEmpty {
            individuals = sortByRecency(cached)
            dispatcherToSessions[item.jid] = Set(cached.map { $0.jid })
            isLoadingIndividuals = false
            individualsLoadedOnce = true
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
        selectedSessionJid = item.jid
        chatTarget = .individual(item.jid)
        lastSelectedIndividualJid = item.jid
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
        awaitingNewSession = true
        pollForNewSession(dispatcherJid: dispatcherJid)
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
                knownIndividualJids = Set(individuals.map { $0.jid })
                awaitingNewSession = true
                pollForNewSession(dispatcherJid: dispatcherJid)
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
                knownIndividualJids = Set(individuals.map { $0.jid })
                awaitingNewSession = true
                pollForNewSession(dispatcherJid: dispatcherJid)
            }
        }
    }

    /// Jump to the session that has been waiting for a reply the longest.
    /// Returns true when a target session was found and selected.
    @discardableResult
    public func focusOldestWaitingSession() -> Bool {
        let unread = xmpp.chatStore.unreadByThread
        guard !unread.isEmpty else { return false }

        let dispatcherJids = Set(dispatchers.map { $0.jid })

        let candidates: [(jid: String, waitingSince: Date, dispatcherJid: String?)] = unread.compactMap { threadJid, count in
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

        guard let target = candidates.min(by: { a, b in
            if a.waitingSince != b.waitingSince {
                return a.waitingSince < b.waitingSince
            }
            return a.jid.localizedStandardCompare(b.jid) == .orderedAscending
        }) else {
            return false
        }

        selectSessionThread(jid: target.jid, dispatcherJid: target.dispatcherJid)
        return true
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

        for (dispatcherJid, sessionJids) in dispatcherToSessions {
            if sessionJids.contains(sessionJid) {
                return dispatcherJid
            }
        }

        for (dispatcherJid, cachedItems) in sessionsByDispatcher {
            if cachedItems.contains(where: { $0.jid == sessionJid }) {
                return dispatcherJid
            }
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

    private func pollForNewSession(dispatcherJid: String, remaining: Int = 5) {
        guard remaining > 0, awaitingNewSession else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.awaitingNewSession else { return }
            guard self.selectedDispatcherJid == dispatcherJid else {
                self.awaitingNewSession = false
                return
            }
            self.refreshSessionsForDispatcher(dispatcherJid: dispatcherJid)
            self.pollForNewSession(dispatcherJid: dispatcherJid, remaining: remaining - 1)
        }
    }

    private func autoSelectNewSessionIfNeeded() {
        guard awaitingNewSession else { return }
        guard case .dispatcher = chatTarget else {
            awaitingNewSession = false
            return
        }
        let currentJids = Set(individuals.map { $0.jid })
        let newJids = currentJids.subtracting(knownIndividualJids)
        guard let newJid = newJids.first,
              let newItem = individuals.first(where: { $0.jid == newJid }) else {
            return
        }
        awaitingNewSession = false
        selectIndividual(newItem)
    }

    // MARK: - Dispatchers (fetched once, cached permanently)

    private func refreshDispatchers() {
        let node = nodes.dispatchers
        ensureSubscribed(to: node)
        queryItems(node: node) { [weak self] items in
            guard let self else { return }
            self.dispatchers = items
            self.dispatchersLoaded = true

            // If nothing is selected yet, pick the first dispatcher and load sessions.
            if self.selectedDispatcherJid == nil, let first = self.dispatchers.first {
                self.selectDispatcher(first)
            }
        }
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
        dispatcherToSessions[dispatcherJid] = Set(sorted.map { $0.jid })

        if selectedDispatcherJid == dispatcherJid {
            individuals = sorted
            suppressResortUntil = Date().addingTimeInterval(1.5)
            scheduleResortAfterSuppression()
            probeRecencyForAllSessions()
            loadHistoryForAllSessions()
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
                        // Dispatcher node format: "N" or "N:direct" (sort position).
                        // Session node format: nil (active) or "closed".
                        var isDirect = false
                        var isClosed = false
                        var sortOrder = Int.max
                        if let nodeStr = item.node {
                            if nodeStr == "closed" {
                                isClosed = true
                            } else {
                                let parts = nodeStr.split(separator: ":", maxSplits: 1)
                                if let pos = Int(parts[0]) {
                                    sortOrder = pos
                                }
                                if parts.count > 1, parts[1] == "direct" {
                                    isDirect = true
                                }
                            }
                        }
                        return DirectoryItem(
                            jid: item.jid.bareJid.stringValue,
                            name: item.name,
                            isDirect: isDirect,
                            sortOrder: sortOrder,
                            isClosed: isClosed
                        )
                    }.sorted { $0.sortOrder < $1.sortOrder }
                    assign(mapped)
                case .failure:
                    assign([])
                }
            }
        }
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
        xmpp.chatStore.$threads
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleResort()
            }
            .store(in: &cancellables)

        // Re-sort when we learn timestamps without storing message bodies.
        xmpp.chatStore.$lastActivityByThread
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleResort()
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
            items.append(DirectoryItem(jid: jid, name: name, isClosed: isClosed))
        }
        return items
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
        individuals = sortByRecency(individuals)
    }

    private func loadHistoryForAllSessions() {
        let raw = ProcessInfo.processInfo.environment["SWITCH_PREFETCH_HISTORY_THREADS"] ?? "0"
        let parsed = Int(raw) ?? 0
        let limit = max(0, min(parsed, 50))
        guard limit > 0 else { return }

        for item in individuals.prefix(limit) {
            xmpp.ensureHistoryLoaded(with: item.jid)
        }
    }

    private func probeRecencyForAllSessions() {
        let raw = ProcessInfo.processInfo.environment["SWITCH_RECENCY_PROBE_THREADS"] ?? "5000"
        let parsed = Int(raw) ?? 5000
        let limit = max(0, min(parsed, 5000))
        guard limit > 0 else { return }

        for item in individuals.filter({ !$0.isClosed }).prefix(limit) {
            xmpp.ensureRecencyProbed(with: item.jid)
        }
    }

    private func sortByRecency(_ items: [DirectoryItem]) -> [DirectoryItem] {
        // Active sessions sorted by recency, closed sessions keep server order at the end.
        let active = items.filter { !$0.isClosed }
        let closed = items.filter { $0.isClosed }
        let chatStore = xmpp.chatStore
        let sortedActive = active.sorted { a, b in
            let aTime = chatStore.lastActivityByThread[a.jid] ?? chatStore.messages(for: a.jid).last?.timestamp ?? .distantPast
            let bTime = chatStore.lastActivityByThread[b.jid] ?? chatStore.messages(for: b.jid).last?.timestamp ?? .distantPast
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
