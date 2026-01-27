import Combine
import Foundation
import Martin

@MainActor
public final class SwitchDirectoryService: ObservableObject {
    @Published public private(set) var dispatchers: [DirectoryItem] = []
    @Published public private(set) var groups: [DirectoryItem] = []
    @Published public private(set) var individuals: [DirectoryItem] = []
    @Published public private(set) var subagents: [DirectoryItem] = []

    @Published public var navigationSelection: NavigationSelection? = nil
    @Published public private(set) var chatTarget: ChatTarget? = nil

    private let xmpp: XMPPService
    private let directoryJid: JID
    private let directoryBareJid: BareJID
    private let pubSubBareJid: BareJID?
    private let nodes: SwitchDirectoryNodes
    private var cancellables: Set<AnyCancellable> = []
    private var subscribedNodes: Set<String> = []
    private var lastSelectedIndividualJid: String? = nil

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
        bindSelectionPipeline()
        bindPubSubRefresh()
    }

    public func refreshAll() {
        refreshDispatchers()
        refreshChildListsForCurrentSelection()
    }

    public func selectDispatcher(_ item: DirectoryItem) {
        navigationSelection = .dispatcher(item.jid)
        chatTarget = .dispatcher(item.jid)
        lastSelectedIndividualJid = nil
    }

    public func selectGroup(_ item: DirectoryItem) {
        navigationSelection = .group(item.jid)
    }

    public func selectIndividual(_ item: DirectoryItem) {
        navigationSelection = .individual(item.jid)
        chatTarget = .individual(item.jid)
        lastSelectedIndividualJid = item.jid
    }

    public func selectSubagent(_ item: DirectoryItem) {
        navigationSelection = .subagent(item.jid)
        chatTarget = .subagent(item.jid)
    }

    public func sendChat(body: String) {
        guard let target = chatTarget else { return }
        let jid: String
        switch target {
        case .dispatcher(let j), .individual(let j), .subagent(let j):
            jid = j
        }

        switch target {
        case .subagent:
            let taskId = UUID().uuidString
            let parent = lastSelectedIndividualJid ?? xmpp.client.userBareJid.stringValue
            xmpp.sendSubagentWork(to: jid, taskId: taskId, parentJid: parent, body: body)
        case .dispatcher, .individual:
            xmpp.sendMessage(to: jid, body: body)
        }
    }

    public func messagesForActiveChat() -> [ChatMessage] {
        guard let target = chatTarget else { return [] }
        let jid: String
        switch target {
        case .dispatcher(let j), .individual(let j), .subagent(let j):
            jid = j
        }
        return xmpp.chatStore.messages(for: jid)
    }

    private func refreshDispatchers() {
        let node = nodes.dispatchers
        ensureSubscribed(to: node) { [weak self] in
            self?.queryItems(node: node) { items in
                self?.dispatchers = items
            }
        }
    }

    private func refreshChildListsForCurrentSelection() {
        switch navigationSelection {
        case .dispatcher(let dispatcherJid):
            refreshGroups(dispatcherJid: dispatcherJid)
            individuals = []
            subagents = []
        case .group(let groupJid):
            refreshIndividuals(groupJid: groupJid)
            subagents = []
        case .individual(let individualJid):
            refreshSubagents(individualJid: individualJid)
        case .subagent:
            break
        case .none:
            groups = []
            individuals = []
            subagents = []
        }
    }

    private func refreshGroups(dispatcherJid: String) {
        let node = nodes.groups(dispatcherJid)
        ensureSubscribed(to: node) { [weak self] in
            self?.queryItems(node: node) { items in
                self?.groups = items
            }
        }
    }

    private func refreshIndividuals(groupJid: String) {
        let node = nodes.individuals(groupJid)
        ensureSubscribed(to: node) { [weak self] in
            self?.queryItems(node: node) { items in
                self?.individuals = items
            }
        }
    }

    private func refreshSubagents(individualJid: String) {
        let node = nodes.subagents(individualJid)
        ensureSubscribed(to: node) { [weak self] in
            self?.queryItems(node: node) { items in
                self?.subagents = items
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

    private func bindSelectionPipeline() {
        $navigationSelection
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshChildListsForCurrentSelection()
            }
            .store(in: &cancellables)
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
    }
}
