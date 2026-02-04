import Combine
import CryptoKit
import Foundation
import Martin
import os

private let logger = Logger(subsystem: "com.switch.macos", category: "XMPPService")

public let switchMetaNamespace = "urn:switch:message-meta"

private let oobNamespace = "jabber:x:oob"

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

private func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func buildOobElement(url: String, desc: String?) -> Element {
    let x = Element(name: "x", xmlns: oobNamespace)
    let u = Element(name: "url", cdata: url, xmlns: oobNamespace)
    x.addChild(u)
    if let desc, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let d = Element(name: "desc", cdata: desc, xmlns: oobNamespace)
        x.addChild(d)
    }
    return x
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
    case "attachment":
        metaType = .attachment
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

    var attachments: [SwitchAttachment]? = nil
    if metaType == .attachment, let payloadJson {
        attachments = SwitchAttachmentCodec.decodeAttachments(from: payloadJson)
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

    return MessageMeta(type: metaType, tool: tool, runStats: runStats, requestId: requestId, question: question, attachments: attachments)
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

    /// Avatar image bytes keyed by bare JID (XEP-0084 PEP user avatar)
    @Published public private(set) var avatarDataByJid: [String: Data] = [:]
    private var avatarLoadingJids: Set<String> = []

    @Published public private(set) var status: Status = .disconnected
    @Published public private(set) var statusText: String = "Disconnected"

    private let messageModule: MessageModule
    private let pubSubModule: PubSubModule
    private let mamModule: MessageArchiveManagementModule
    private let chatStateModule: ChatStateNotificationsModule
    private let httpUploadModule: HttpFileUploadModule
    private let pepUserAvatarModule: PEPUserAvatarModule
    private let vcardTempModule: VCardTempModule
    private var cancellables: Set<AnyCancellable> = []

    private var mamQueryToThread: [String: String] = [:]
    private enum MamQueryMode: String, Sendable {
        case history
        case recencyProbe
    }
    private var mamQueryMode: [String: MamQueryMode] = [:]
    private var mamRouteCleanup: [String: DispatchWorkItem] = [:]
    private let mamRouteGraceSeconds: TimeInterval = 30

    private var historyLoadedThreads: Set<String> = []
    private var historyLoadingThreads: Set<String> = []
    private var historyQueuedThreads: Set<String> = []
    private var historyQueue: [String] = []
    private var isProcessingHistoryQueue: Bool = false

    private var recencyProbedThreads: Set<String> = []
    private var recencyLoadingThreads: Set<String> = []
    private var recencyQueuedThreads: Set<String> = []
    private var recencyQueue: [String] = []
    private var isProcessingRecencyQueue: Bool = false

    /// True while we're draining the initial MAM history queue.
    @Published public private(set) var isHistoryWarmup: Bool = false

    // MAM history pulls can be expensive on first launch; keep the default small.
    // Override via env: SWITCH_MAM_LAST_ITEMS (10..500).
    private let mamLastItems: Int
    private let mamRecencyLastItems: Int

    private var cachedUploadComponents: [HttpFileUploadModule.UploadComponent] = []

    /// JIDs currently in "composing" (typing) state
    @Published public private(set) var composingJids: Set<String> = []

    public init() {
        let chatManager = DefaultChatManager(store: DefaultChatStore())
        self.messageModule = MessageModule(chatManager: chatManager)
        self.pubSubModule = PubSubModule()
        self.mamModule = MessageArchiveManagementModule()
        self.chatStateModule = ChatStateNotificationsModule()
        self.httpUploadModule = HttpFileUploadModule()
        self.pepUserAvatarModule = PEPUserAvatarModule()
        self.vcardTempModule = VCardTempModule()

        let rawMamLast = ProcessInfo.processInfo.environment["SWITCH_MAM_LAST_ITEMS"] ?? "50"
        let parsedMamLast = Int(rawMamLast) ?? 50
        self.mamLastItems = max(10, min(parsedMamLast, 500))

        let rawMamRecencyLast = ProcessInfo.processInfo.environment["SWITCH_MAM_RECENCY_LAST_ITEMS"] ?? "1"
        let parsedMamRecencyLast = Int(rawMamRecencyLast) ?? 1
        self.mamRecencyLastItems = max(1, min(parsedMamRecencyLast, 5))

        registerDefaultModules()
        bindPublishers()
    }

    public func ensureAvatarLoaded(for bareJid: String) {
        let jid = bareJid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jid.isEmpty else { return }
        if avatarDataByJid[jid] != nil { return }
        if avatarLoadingJids.contains(jid) { return }
        avatarLoadingJids.insert(jid)

        pepUserAvatarModule.retrieveAvatarMetadata(from: BareJID(jid), itemId: nil, fireEvents: false) { [weak self] metaResult in
            guard let self else { return }
            switch metaResult {
            case .success(let info):
                self.pepUserAvatarModule.retrieveAvatar(from: BareJID(jid), itemId: info.id) { [weak self] dataResult in
                    guard let self else { return }
                    Task { @MainActor in
                        defer { self.avatarLoadingJids.remove(jid) }
                        switch dataResult {
                        case .success((_, let data)):
                            self.avatarDataByJid[jid] = data
                        case .failure:
                            // Fallback: servers may only provide vCard-based photos.
                            self.loadVCardTempAvatarIfPresent(for: jid)
                        }
                    }
                }
            case .failure:
                // Fallback: servers may only provide vCard-based photos.
                self.loadVCardTempAvatarIfPresent(for: jid)
            }
        }
    }

    private func loadVCardTempAvatarIfPresent(for bareJid: String) {
        let jid = bareJid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jid.isEmpty else { return }

        vcardTempModule.retrieveVCard(from: JID(jid)) { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                defer { self.avatarLoadingJids.remove(jid) }
                guard case .success(let vcard) = result else { return }
                guard let photo = vcard.photos.first(where: { ($0.binval ?? "").isEmpty == false }) else { return }
                guard let binval = photo.binval else { return }
                guard let data = Data(base64Encoded: binval, options: [.ignoreUnknownCharacters]) else { return }
                self.avatarDataByJid[jid] = data
            }
        }
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
        _ = client.disconnect()
    }

    public func sendMessage(to bareJid: String, body: String) {
        sendWireMessage(to: bareJid, wireBody: body, displayBody: body, metaElement: nil, metaForStore: nil)
    }

    public func sendImageAttachment(to bareJid: String, data: Data, filename: String, mime: String, caption: String?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let component = try await self.pickUploadComponent(for: data.count)
                let slot = try await self.httpUploadModule.requestUploadSlot(componentJid: component.jid, filename: filename, size: data.count, contentType: mime)
                try await self.putUpload(data: data, to: slot.putUri, mime: mime, extraHeaders: slot.putHeaders)

                let urlStr = slot.getUri.absoluteString
                let trimmedCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasCaption = (trimmedCaption?.isEmpty == false)
                let wireBody = hasCaption ? "\(trimmedCaption!)\n\(urlStr)" : urlStr

                let attachment = SwitchAttachment(
                    id: UUID().uuidString,
                    kind: "image",
                    mime: mime,
                    localPath: nil,
                    publicUrl: urlStr,
                    filename: filename,
                    sizeBytes: data.count,
                    sha256: sha256Hex(data)
                )
                let payloadJson = SwitchAttachmentCodec.encodePayloadJson(attachments: [attachment])
                let metaEl = buildSwitchMetaElement(type: "attachment", attrs: ["version": "1"], payloadJson: payloadJson)
                let metaForStore = MessageMeta(type: .attachment, attachments: [attachment])

                let oob = buildOobElement(url: urlStr, desc: trimmedCaption)
                self.sendWireMessage(
                    to: bareJid,
                    wireBody: wireBody,
                    displayBody: wireBody,
                    metaElement: metaEl,
                    metaForStore: metaForStore,
                    extraElements: [oob]
                )
            } catch {
                logger.error("Image upload failed: \(String(describing: error), privacy: .public)")
            }
        }
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

    private func sendWireMessage(to bareJid: String, wireBody: String, displayBody: String, metaElement: Element?, metaForStore: MessageMeta?, extraElements: [Element] = []) {
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
        for el in extraElements {
            msg.element.addChild(el)
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
        let jid = bareJid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jid.isEmpty else { return }

        if historyLoadedThreads.contains(jid) || historyLoadingThreads.contains(jid) || historyQueuedThreads.contains(jid) {
            return
        }

        historyQueuedThreads.insert(jid)
        historyQueue.append(jid)
        isHistoryWarmup = true
        processHistoryQueueIfNeeded()
    }

    private func processHistoryQueueIfNeeded() {
        guard !isProcessingHistoryQueue else { return }
        isProcessingHistoryQueue = true
        processNextHistoryLoad()
    }

    private func processNextHistoryLoad() {
        guard let next = historyQueue.first else {
            isProcessingHistoryQueue = false
            if historyLoadingThreads.isEmpty && historyQueuedThreads.isEmpty {
                isHistoryWarmup = false
            }
            return
        }
        historyQueue.removeFirst()
        historyQueuedThreads.remove(next)
        historyLoadingThreads.insert(next)

        let queryId = UUID().uuidString
        mamQueryToThread[queryId] = next
        mamQueryMode[queryId] = .history
        scheduleMamRouteCleanup(queryId: queryId)

        let form = MAMQueryForm(version: .MAM2)
        form.with = JID(next)

        mamModule.queryItems(
            version: .MAM2,
            query: form,
            queryId: queryId,
            rsm: RSM.Query(lastItems: mamLastItems)
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.historyLoadingThreads.remove(next)
                switch result {
                case .success:
                    self.historyLoadedThreads.insert(next)
                case .failure(let err):
                    logger.error("MAM query failed for \(next, privacy: .public): \(String(describing: err), privacy: .public)")
                }

                if self.historyQueue.isEmpty && self.historyLoadingThreads.isEmpty && self.historyQueuedThreads.isEmpty {
                    self.isHistoryWarmup = false
                }

                // Keep routing archived messages briefly after completion. Some servers/libraries
                // can deliver the final batch slightly after the completion callback fires.
                self.scheduleMamRouteCleanup(queryId: queryId)

                self.processNextHistoryLoad()
            }
        }
    }

    private func scheduleMamRouteCleanup(queryId: String) {
        if let existing = mamRouteCleanup[queryId] {
            existing.cancel()
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.mamQueryToThread.removeValue(forKey: queryId)
                self.mamQueryMode.removeValue(forKey: queryId)
                self.mamRouteCleanup.removeValue(forKey: queryId)
            }
        }
        mamRouteCleanup[queryId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + mamRouteGraceSeconds, execute: work)
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

    /// Ensure we know *something* about thread recency without loading full history.
    /// This runs a cheap MAM query (`lastItems` ~= 1) and only updates `chatStore.lastActivityByThread`.
    public func ensureRecencyProbed(with bareJid: String) {
        let jid = bareJid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jid.isEmpty else { return }
        if recencyProbedThreads.contains(jid) || recencyLoadingThreads.contains(jid) || recencyQueuedThreads.contains(jid) {
            return
        }
        recencyQueuedThreads.insert(jid)
        recencyQueue.append(jid)
        processRecencyQueueIfNeeded()
    }

    private func processRecencyQueueIfNeeded() {
        guard !isProcessingRecencyQueue else { return }
        isProcessingRecencyQueue = true
        processNextRecencyProbe()
    }

    private func processNextRecencyProbe() {
        guard let next = recencyQueue.first else {
            isProcessingRecencyQueue = false
            return
        }
        recencyQueue.removeFirst()
        recencyQueuedThreads.remove(next)
        recencyLoadingThreads.insert(next)

        let queryId = UUID().uuidString
        mamQueryToThread[queryId] = next
        mamQueryMode[queryId] = .recencyProbe
        scheduleMamRouteCleanup(queryId: queryId)

        let form = MAMQueryForm(version: .MAM2)
        form.with = JID(next)

        mamModule.queryItems(
            version: .MAM2,
            query: form,
            queryId: queryId,
            rsm: RSM.Query(lastItems: mamRecencyLastItems)
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.recencyLoadingThreads.remove(next)
                switch result {
                case .success:
                    self.recencyProbedThreads.insert(next)
                case .failure(let err):
                    logger.error("MAM recency probe failed for \(next, privacy: .public): \(String(describing: err), privacy: .public)")
                }
                self.scheduleMamRouteCleanup(queryId: queryId)
                self.processNextRecencyProbe()
            }
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
        client.modulesManager.register(httpUploadModule)
        client.modulesManager.register(pepUserAvatarModule)
        client.modulesManager.register(vcardTempModule)
    }

    private func pickUploadComponent(for byteCount: Int) async throws -> HttpFileUploadModule.UploadComponent {
        if let ok = cachedUploadComponents.first(where: { $0.maxSize >= byteCount }) {
            return ok
        }
        let found = try await httpUploadModule.findHttpUploadComponents()
        cachedUploadComponents = found
        if let ok = found.first(where: { $0.maxSize >= byteCount }) {
            return ok
        }
        throw XMPPError.not_acceptable()
    }

    private func putUpload(data: Data, to url: URL, mime: String, extraHeaders: [String: String]) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        for (k, v) in extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (_, resp) = try await URLSession.shared.upload(for: req, from: data)
        if let http = resp as? HTTPURLResponse {
            if !(200...299).contains(http.statusCode) {
                throw NSError(domain: "HttpFileUpload", code: http.statusCode)
            }
        }
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

        pepUserAvatarModule.avatarChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                let bare = change.jid.bareJid.stringValue
                // Force a refresh; the cached bytes may now be stale.
                self.avatarDataByJid[bare] = nil
                self.ensureAvatarLoaded(for: bare)
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
                let mode = self.mamQueryMode[archived.query.id] ?? .history

                // Extend routing window while results are streaming in.
                self.scheduleMamRouteCleanup(queryId: archived.query.id)

                // Always record activity for sorting, even if the message has no body.
                self.chatStore.noteActivity(threadJid: threadJid, timestamp: archived.timestamp)

                // For recency probes we only need the timestamp, not the message body.
                if mode == .recencyProbe {
                    return
                }

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
                    self.chatStore.appendOutgoing(threadJid: threadJid, body: body, id: id, timestamp: archived.timestamp, meta: meta, isArchived: true)
                }
            }
            .store(in: &cancellables)
    }
}
