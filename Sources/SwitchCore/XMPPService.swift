import Combine
import Foundation
import Martin
import os

private let logger = Logger(subsystem: "com.switch.macos", category: "XMPPService")

public let switchMetaNamespace = "urn:switch:message-meta"

/// Parse Switch message metadata from an XMPP message element
public func parseMessageMeta(from element: Element) -> MessageMeta? {
    // Look for direct child: <meta xmlns="urn:switch:message-meta" type="..." tool="..."/>
    guard let metaElement = element.findChild(name: "meta", xmlns: switchMetaNamespace) else {
        return nil
    }

    guard let typeStr = metaElement.attribute("type") else {
        return nil
    }

    let metaType: MessageMeta.MetaType
    switch typeStr {
    case "tool":
        metaType = .tool
    case "tool-result":
        metaType = .toolResult
    default:
        metaType = .unknown
    }

    let tool = metaElement.attribute("tool")

    return MessageMeta(type: metaType, tool: tool)
}

class DebugStreamLogger: StreamLogger {
    func incoming(_ value: StreamEvent) {
        logger.debug("XMPP <<< \(String(describing: value), privacy: .public)")
    }
    func outgoing(_ value: StreamEvent) {
        logger.debug("XMPP >>> \(String(describing: value), privacy: .public)")
    }
}

@MainActor
public final class XMPPService: ObservableObject {
    public enum Status: Sendable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    public let chatStore = ChatStore()
    public let client = XMPPClient()
    private let debugLogger = DebugStreamLogger()

    @Published public private(set) var status: Status = .disconnected
    @Published public private(set) var statusText: String = "Disconnected"

    private let messageModule: MessageModule
    private let pubSubModule: PubSubModule
    private let mamModule: MessageArchiveManagementModule
    private var cancellables: Set<AnyCancellable> = []

    private var mamQueryToThread: [String: String] = [:]
    private var historyLoadedThreads: Set<String> = []
    private var historyLoadingThreads: Set<String> = []

    public init() {
        let chatManager = DefaultChatManager(store: DefaultChatStore())
        self.messageModule = MessageModule(chatManager: chatManager)
        self.pubSubModule = PubSubModule()
        self.mamModule = MessageArchiveManagementModule()

        registerDefaultModules()
        bindPublishers()
    }

    public func connect(using config: AppConfig) {
        client.streamLogger = debugLogger
        logger.info("Connecting to \(config.xmppHost, privacy: .public):\(config.xmppPort) as \(config.xmppJid, privacy: .public)")
        configureClient(using: config)
        status = .connecting
        statusText = "Connecting..."
        client.login()
    }

    public func disconnect() {
        client.disconnect()
    }

    public func sendMessage(to bareJid: String, body: String) {
        sendWireMessage(to: bareJid, wireBody: body, displayBody: body)
    }

    public func sendSubagentWork(to subagentJid: String, taskId: String, parentJid: String, body: String) {
        let envelope = SubagentWorkEnvelope(taskId: taskId, parentJid: parentJid, body: body)
        guard let encoded = SubagentWorkCodec.encode(envelope) else {
            return
        }
        sendWireMessage(to: subagentJid, wireBody: encoded, displayBody: body)
    }

    private func sendWireMessage(to bareJid: String, wireBody: String, displayBody: String) {
        let to = BareJID(bareJid)
        let chat = messageModule.chatManager.createChat(for: client, with: to)
        guard let conversation = chat as? ConversationBase else {
            return
        }
        let id = UUID().uuidString
        let msg = conversation.createMessage(text: wireBody, id: id)
        conversation.send(message: msg, completionHandler: nil)

        chatStore.appendOutgoing(threadJid: bareJid, body: displayBody, id: msg.id, timestamp: Date())
    }

    public var pubSubItemsEvents: AnyPublisher<PubSubModule.ItemNotification, Never> {
        pubSubModule.itemsEvents
    }

    public var pubSubNodesEvents: AnyPublisher<PubSubModule.NodeNotification, Never> {
        pubSubModule.nodesEvents
    }

    public func disco() -> DiscoveryModule {
        client.module(.disco)
    }

    public func pubsub() -> PubSubModule {
        client.module(.pubsub)
    }

    public func ensureHistoryLoaded(with bareJid: String) {
        if historyLoadedThreads.contains(bareJid) || historyLoadingThreads.contains(bareJid) {
            return
        }
        historyLoadingThreads.insert(bareJid)

        let queryId = UUID().uuidString
        mamQueryToThread[queryId] = bareJid

        let form = MAMQueryForm(version: .MAM2)
        form.with = JID(bareJid)

        mamModule.queryItems(version: .MAM2, query: form, queryId: queryId, rsm: RSM.Query(lastItems: 200)) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.historyLoadingThreads.remove(bareJid)
                switch result {
                case .success:
                    self.historyLoadedThreads.insert(bareJid)
                case .failure(let err):
                    logger.error("MAM query failed for \(bareJid, privacy: .public): \(String(describing: err), privacy: .public)")
                }

                // Results can still be in flight for a moment; keep routing briefly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.mamQueryToThread.removeValue(forKey: queryId)
                }
            }
        }
    }

    private func configureClient(using config: AppConfig) {
        client.connectionConfiguration.userJid = BareJID(config.xmppJid)
        client.connectionConfiguration.credentials = .password(password: config.xmppPassword)
        client.connectionConfiguration.disableCompression = false

        client.connectionConfiguration.modifyConnectorOptions(type: SocketConnectorNetwork.Options.self) { options in
            options.connectionDetails = .init(proto: .XMPP, host: config.xmppHost, port: config.xmppPort)
            options.connectionTimeout = 15
        }
    }

    private func registerDefaultModules() {
        client.modulesManager.register(AuthModule())
        client.modulesManager.register(StreamFeaturesModule())
        client.modulesManager.register(SaslModule())
        client.modulesManager.register(ResourceBinderModule())
        client.modulesManager.register(SessionEstablishmentModule())
        client.modulesManager.register(DiscoveryModule())
        client.modulesManager.register(SoftwareVersionModule())
        client.modulesManager.register(PingModule())
        client.modulesManager.register(PresenceModule())
        client.modulesManager.register(mamModule)
        client.modulesManager.register(messageModule)
        client.modulesManager.register(pubSubModule)
    }

    private func bindPublishers() {
        client.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state == .connected() {
                    self.status = .connected
                    self.statusText = "Connected"
                } else if state == .connecting {
                    self.status = .connecting
                    self.statusText = "Connecting..."
                } else if case .disconnected(let reason) = state {
                    logger.error("Disconnected: \(String(describing: reason), privacy: .public)")
                    self.status = .disconnected
                    self.statusText = "Disconnected (\(String(describing: reason)))"
                } else {
                    self.statusText = String(describing: state)
                }
            }
            .store(in: &cancellables)

        messageModule.messagesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] received in
                guard let self else { return }
                guard let from = received.message.from?.bareJid.stringValue else { return }
                guard let body = received.message.body else { return }
                let meta = parseMessageMeta(from: received.message.element)
                self.chatStore.appendIncoming(threadJid: from, body: body, id: received.message.id, timestamp: received.message.delay?.stamp ?? Date(), meta: meta)
            }
            .store(in: &cancellables)

        mamModule.archivedMessagesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] archived in
                guard let self else { return }
                guard let threadJid = self.mamQueryToThread[archived.query.id] else { return }
                guard let body = archived.message.body, !body.isEmpty else { return }

                let localBare = self.client.userBareJid
                let fromBare = archived.message.from?.bareJid
                let direction: ChatMessage.Direction = (fromBare == localBare) ? .outgoing : .incoming
                let id = "mam:\(archived.messageId)"
                let meta = parseMessageMeta(from: archived.message.element)

                switch direction {
                case .incoming:
                    self.chatStore.appendIncoming(threadJid: threadJid, body: body, id: id, timestamp: archived.timestamp, meta: meta, isArchived: true)
                case .outgoing:
                    self.chatStore.appendOutgoing(threadJid: threadJid, body: body, id: id, timestamp: archived.timestamp, meta: meta)
                }
            }
            .store(in: &cancellables)
    }
}
