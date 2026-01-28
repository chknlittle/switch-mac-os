import Combine
import Foundation
import Martin
import os

private let logger = Logger(subsystem: "com.switch.macos", category: "XMPPService")

public let switchMetaNamespace = "urn:switch:message-meta"

private func localName(of raw: String) -> String {
    // Handles:
    // - "meta" / "payload"
    // - "ns0:meta" (prefix form)
    // - "{urn:switch:message-meta}meta" (Clark notation)
    if let braceIdx = raw.lastIndex(of: "}") {
        let after = raw.index(after: braceIdx)
        if after < raw.endIndex {
            return String(raw[after...])
        }
    }
    if let colonIdx = raw.lastIndex(of: ":") {
        let after = raw.index(after: colonIdx)
        if after < raw.endIndex {
            return String(raw[after...])
        }
    }
    return raw
}

private func isSwitchMetaElement(_ el: Element, localName: String) -> Bool {
    if el.xmlns == switchMetaNamespace {
        return el.name == localName || el.name.hasSuffix(":\(localName)") || el.name.hasSuffix("}\(localName)")
    }
    // Some XML parsers preserve the namespace in Clark notation in the element name.
    // Example: "{urn:switch:message-meta}meta"
    let clarkPrefix = "{\(switchMetaNamespace)}"
    if el.name.hasPrefix(clarkPrefix) {
        return el.name == "\(clarkPrefix)\(localName)"
    }
    return false
}

private func decodeJSON<T: Decodable>(_ type: T.Type, from json: String) -> T? {
    guard let data = json.data(using: .utf8) else { return nil }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        logger.notice("Failed to decode JSON payload: \(String(describing: error), privacy: .public)")
        return nil
    }
}

public func buildSwitchMetaElement(type: String, tool: String? = nil, attrs: [String: String] = [:], payloadJson: String? = nil) -> Element {
    let meta = Element(name: "meta", xmlns: switchMetaNamespace)
    meta.attribute("type", newValue: type)
    if let tool {
        meta.attribute("tool", newValue: tool)
    }
    for (k, v) in attrs {
        if k == "type" || k == "tool" { continue }
        meta.attribute(k, newValue: v)
    }
    if let payloadJson {
        let payload = Element(name: "payload", cdata: payloadJson, xmlns: switchMetaNamespace)
        payload.attribute("format", newValue: "json")
        meta.addChild(payload)
    }
    return meta
}

/// Parse Switch message metadata from an XMPP message element
public func parseMessageMeta(from element: Element) -> MessageMeta? {
    // Look for direct child:
    // <meta xmlns="urn:switch:message-meta" type="..."> ... </meta>
    // Be tolerant of namespace prefixes in parsed element names.
    let metaElement = element.children.first(where: { isSwitchMetaElement($0, localName: "meta") || localName(of: $0.name) == "meta" })
    guard let metaElement else {
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
    case "run-stats":
        metaType = .runStats
    case "question":
        metaType = .question
    case "question-reply":
        metaType = .questionReply
    default:
        metaType = .unknown
    }

    let tool = metaElement.attribute("tool")

    let requestId = metaElement.attribute("request_id")

    // Parse JSON payload if present
    var payloadJson: String? = nil
    if let payloadElement = metaElement.children.first(where: { localName(of: $0.name) == "payload" }) {
        if (payloadElement.attribute("format") ?? "").lowercased() == "json" {
            payloadJson = payloadElement.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var question: SwitchQuestionEnvelopeV1? = nil
    if metaType == .question, let payloadJson {
        question = decodeJSON(SwitchQuestionEnvelopeV1.self, from: payloadJson)
    }

    if metaType == .question, question == nil {
        logger.notice("Question meta present but payload decode failed")
        logger.notice("meta.name=\(metaElement.name, privacy: .public) meta.xmlns=\(metaElement.xmlns ?? "nil", privacy: .public)")
        let childNames = metaElement.children.map { "\($0.name)[\($0.xmlns ?? "nil")]" }.joined(separator: ", ")
        logger.notice("meta.children=\(childNames, privacy: .public)")
        if let payloadElement = metaElement.children.first(where: { localName(of: $0.name) == "payload" }) {
            logger.notice("payload.name=\(payloadElement.name, privacy: .public) payload.xmlns=\(payloadElement.xmlns ?? "nil", privacy: .public)")
            logger.notice("payload.format=\((payloadElement.attribute("format") ?? "nil"), privacy: .public)")
            let val = payloadElement.value ?? ""
            logger.notice("payload.value.len=\(val.count, privacy: .public)")
        }
    }

    // Parse run-stats attributes if present
    var runStats: RunStats? = nil
    if metaType == .runStats {
        runStats = RunStats(
            engine: metaElement.attribute("engine"),
            model: metaElement.attribute("model"),
            tokensIn: metaElement.attribute("tokens_in"),
            tokensOut: metaElement.attribute("tokens_out"),
            tokensReasoning: metaElement.attribute("tokens_reasoning"),
            tokensCacheRead: metaElement.attribute("tokens_cache_read"),
            tokensCacheWrite: metaElement.attribute("tokens_cache_write"),
            tokensTotal: metaElement.attribute("tokens_total"),
            contextWindow: metaElement.attribute("context_window"),
            turns: metaElement.attribute("turns"),
            toolCount: metaElement.attribute("tool_count"),
            costUsd: metaElement.attribute("cost_usd"),
            durationS: metaElement.attribute("duration_s"),
            summary: metaElement.attribute("summary")
        )
    }

    return MessageMeta(type: metaType, tool: tool, runStats: runStats, requestId: requestId, question: question)
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
    private let chatStateModule: ChatStateNotificationsModule
    private var cancellables: Set<AnyCancellable> = []

    private var mamQueryToThread: [String: String] = [:]
    private var historyLoadedThreads: Set<String> = []
    private var historyLoadingThreads: Set<String> = []

    /// JIDs currently in "composing" (typing) state
    @Published public private(set) var composingJids: Set<String> = []

    public init() {
        let chatManager = DefaultChatManager(store: DefaultChatStore())
        self.messageModule = MessageModule(chatManager: chatManager)
        self.pubSubModule = PubSubModule()
        self.mamModule = MessageArchiveManagementModule()
        self.chatStateModule = ChatStateNotificationsModule()

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
        sendWireMessage(to: bareJid, wireBody: body, displayBody: body, metaElement: nil, metaForStore: nil)
    }

    public func sendQuestionReply(to bareJid: String, requestId: String, answers: [[String]]?, text: String? = nil, displayText: String) {
        let envelope = SwitchQuestionReplyEnvelopeV1(version: 1, requestId: requestId, answers: answers, text: text)
        let payloadData = try? JSONEncoder().encode(envelope)
        let payloadJson = payloadData.flatMap { String(data: $0, encoding: .utf8) }

        let meta = buildSwitchMetaElement(
            type: "question-reply",
            tool: "question",
            attrs: [
                "version": "1",
                "request_id": requestId
            ],
            payloadJson: payloadJson
        )

        let metaForStore = MessageMeta(type: .questionReply, tool: "question", runStats: nil, requestId: requestId, question: nil)
        sendWireMessage(to: bareJid, wireBody: displayText, displayBody: displayText, metaElement: meta, metaForStore: metaForStore)
    }

    public func sendSubagentWork(to subagentJid: String, taskId: String, parentJid: String, body: String) {
        let envelope = SubagentWorkEnvelope(taskId: taskId, parentJid: parentJid, body: body)
        guard let encoded = SubagentWorkCodec.encode(envelope) else {
            return
        }
        sendWireMessage(to: subagentJid, wireBody: encoded, displayBody: body, metaElement: nil, metaForStore: nil)
    }

    private func sendWireMessage(to bareJid: String, wireBody: String, displayBody: String, metaElement: Element?, metaForStore: MessageMeta?) {
        let to = BareJID(bareJid)
        let chat = messageModule.chatManager.createChat(for: client, with: to)
        guard let conversation = chat as? ConversationBase else {
            return
        }
        let id = UUID().uuidString
        let msg = conversation.createMessage(text: wireBody, id: id)
        if let metaElement {
            msg.element.addChild(metaElement)
        }
        conversation.send(message: msg, completionHandler: nil)

        chatStore.appendOutgoing(threadJid: bareJid, body: displayBody, id: msg.id, timestamp: Date(), meta: metaForStore)
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
        client.modulesManager.register(CapabilitiesModule())
        client.modulesManager.register(mamModule)
        client.modulesManager.register(messageModule)
        client.modulesManager.register(pubSubModule)
        client.modulesManager.register(chatStateModule)
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

                // Track chat state (typing indicators)
                if let chatState = received.message.chatState {
                    switch chatState {
                    case .composing:
                        self.composingJids.insert(from)
                    case .active, .inactive, .paused, .gone:
                        self.composingJids.remove(from)
                    }
                }

                // Process message body if present
                guard let body = received.message.body else { return }
                // Receiving a message with body means they're done typing
                self.composingJids.remove(from)
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
