import Combine
import Foundation
import Martin

@MainActor
public final class SwitchDirectoryService: ObservableObject {
    @Published public private(set) var dispatchers: [DirectoryItem] = []
    @Published public private(set) var individuals: [DirectoryItem] = []

    @Published public private(set) var selectedDispatcherJid: String? = nil
    @Published public private(set) var selectedSessionJid: String? = nil
    @Published public private(set) var chatTarget: ChatTarget? = nil

    private let xmpp: XMPPService
    private let directoryJid: JID
    private let directoryBareJid: BareJID
    private let pubSubBareJid: BareJID?
    private let nodes: SwitchDirectoryNodes
    private var cancellables: Set<AnyCancellable> = []
    private var subscribedNodes: Set<String> = []
    private var lastSelectedIndividualJid: String? = nil
    private var individualsRefreshToken: UUID? = nil
    private var groupsRefreshToken: UUID? = nil
    private var awaitingNewSession = false
    private var knownIndividualJids: Set<String> = []

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
        refreshDispatchers()
        if let dispatcher = selectedDispatcherJid {
            refreshSessionsForDispatcher(dispatcherJid: dispatcher)
        } else {
            individuals = []
        }
    }

    public func selectDispatcher(_ item: DirectoryItem) {
        selectedDispatcherJid = item.jid
        selectedSessionJid = nil
        chatTarget = .dispatcher(item.jid)
        lastSelectedIndividualJid = nil
        individuals = []
        refreshSessionsForDispatcher(dispatcherJid: item.jid)
    }

    public func selectIndividual(_ item: DirectoryItem) {
        selectedSessionJid = item.jid
        chatTarget = .individual(item.jid)
        lastSelectedIndividualJid = item.jid
        xmpp.ensureHistoryLoaded(with: item.jid)
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
            knownIndividualJids = Set(individuals.map { $0.jid })
            awaitingNewSession = true
            pollForNewSession(dispatcherJid: dispatcherJid)
        }
    }

    public func messagesForActiveChat() -> [ChatMessage] {
        guard let target = chatTarget else { return [] }
        return xmpp.chatStore.messages(for: target.jid)
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

    private func refreshDispatchers() {
        let node = nodes.dispatchers
        ensureSubscribed(to: node) { [weak self] in
            self?.queryItems(node: node) { items in
                guard let self else { return }
                self.dispatchers = items

                // If nothing is selected yet, pick the first dispatcher and load sessions.
                if self.selectedDispatcherJid == nil, let first = items.first {
                    self.selectDispatcher(first)
                }
            }
        }
    }

    private func refreshSessionsForDispatcher(dispatcherJid: String) {
        let token = UUID()
        groupsRefreshToken = token

        let node = nodes.groups(dispatcherJid)
        ensureSubscribed(to: node) { [weak self] in
            self?.queryItems(node: node) { items in
                guard let self else { return }

                guard self.groupsRefreshToken == token else { return }
                guard self.selectedDispatcherJid == dispatcherJid else { return }
                self.refreshIndividualsForDispatcher(dispatcherJid: dispatcherJid, groups: items)
            }
        }
    }

    private func refreshIndividualsForDispatcher(dispatcherJid: String, groups: [DirectoryItem]) {
        let token = UUID()
        individualsRefreshToken = token

        if groups.isEmpty {
            individuals = []
            return
        }

        if groups.count == 1, let only = groups.first {
            refreshIndividuals(groupJid: only.jid, dispatcherJid: dispatcherJid, token: token)
            return
        }

        var remaining = groups.count
        var aggregate: [String: DirectoryItem] = [:]

        for group in groups {
            let groupJid = group.jid
            let node = nodes.individuals(groupJid)
            ensureSubscribed(to: node) { [weak self] in
                guard let self else { return }
                self.queryItems(node: node) { items in
                    guard self.individualsRefreshToken == token else { return }
                    guard self.selectedDispatcherJid == dispatcherJid else { return }
                    for it in items {
                        aggregate[it.jid] = it
                    }
                    remaining -= 1
                    if remaining == 0 {
                        let merged = self.sortByRecency(Array(aggregate.values))
                        self.individuals = merged
                        self.loadHistoryForAllSessions()
                        self.autoSelectNewSessionIfNeeded()
                    }
                }
            }
        }
    }

    private func refreshIndividuals(groupJid: String, dispatcherJid: String, token: UUID) {
        let node = nodes.individuals(groupJid)
        ensureSubscribed(to: node) { [weak self] in
            self?.queryItems(node: node) { items in
                guard let self else { return }
                guard self.individualsRefreshToken == token else { return }
                guard self.selectedDispatcherJid == dispatcherJid else { return }
                self.individuals = self.sortByRecency(items)
                self.loadHistoryForAllSessions()
                self.autoSelectNewSessionIfNeeded()
            }
        }
    }

    private func queryItems(node: String, assign: @escaping @MainActor ([DirectoryItem]) -> Void) {
        let disco = xmpp.disco()
        disco.getItems(for: directoryJid, node: node) { result in
            Task { @MainActor in
                switch result {
                case .success(let items):
                    assign(items.items.map { DirectoryItem(jid: $0.jid.bareJid.stringValue, name: $0.name) })
                case .failure:
                    assign([])
                }
            }
        }
    }

    private func ensureSubscribed(to node: String, then completion: @escaping @MainActor () -> Void) {
        guard !subscribedNodes.contains(node) else {
            completion()
            return
        }

        let subscriber = xmpp.client.boundJid ?? JID(xmpp.client.userBareJid)
        let service = pubSubBareJid ?? directoryBareJid
        xmpp.pubsub().subscribe(at: service, to: node, subscriber: subscriber, with: nil as JabberDataElement?, completionHandler: { [weak self] _ in
            Task { @MainActor in
                self?.subscribedNodes.insert(node)
                completion()
            }
        })
    }

    private func bindPubSubRefresh() {
        xmpp.pubSubItemsEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                // Skeleton behavior: on any node update, re-run relevant disco queries.
                // This keeps the client correct even if the pubsub payload format evolves.
                if self.subscribedNodes.contains(notification.node) {
                    self.refreshAll()
                }
            }
            .store(in: &cancellables)

        // Re-sort sessions when new messages arrive
        xmpp.chatStore.$threads
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resortIndividualsByRecency()
            }
            .store(in: &cancellables)
    }

    private func resortIndividualsByRecency() {
        guard !individuals.isEmpty else { return }
        individuals = sortByRecency(individuals)
    }

    private func loadHistoryForAllSessions() {
        for item in individuals {
            xmpp.ensureHistoryLoaded(with: item.jid)
        }
    }

    private func sortByRecency(_ items: [DirectoryItem]) -> [DirectoryItem] {
        let chatStore = xmpp.chatStore
        return items.sorted { a, b in
            let aTime = chatStore.messages(for: a.jid).last?.timestamp ?? .distantPast
            let bTime = chatStore.messages(for: b.jid).last?.timestamp ?? .distantPast
            return aTime > bTime
        }
    }
}
