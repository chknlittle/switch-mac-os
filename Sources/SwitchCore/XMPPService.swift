import Combine
import CryptoKit
import Foundation
import Martin
import MartinOMEMO
import os

private let logger = Logger(subsystem: "com.switch.macos", category: "XMPPService")

public let switchMetaNamespace = "urn:switch:message-meta"

private let oobNamespace = "jabber:x:oob"
private let xhtmlImNamespace = "http://jabber.org/protocol/xhtml-im"
private let xhtmlNamespace = "http://www.w3.org/1999/xhtml"
private let sidNamespace = "urn:xmpp:sid:0"
private let replyNamespace = "urn:xmpp:reply:0"
private let omemoNamespace = "eu.siacs.conversations.axolotl"

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

private func buildReplyElement(_ reply: MessageReplyReference) -> Element {
    let el = Element(name: "reply", xmlns: replyNamespace)
    el.attribute("id", newValue: reply.id)
    if let to = reply.to?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty {
        el.attribute("to", newValue: to)
    }
    return el
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

public func parseXHTMLBody(from element: Element) -> String? {
    let htmlElement = element.children.first {
        ($0.xmlns == xhtmlImNamespace && localName(of: $0.name) == "html") ||
        localName(of: $0.name) == "html"
    }
    guard let htmlElement else {
        return nil
    }

    let bodyElement = htmlElement.children.first {
        ($0.xmlns == xhtmlNamespace && localName(of: $0.name) == "body") ||
        localName(of: $0.name) == "body"
    }
    guard let bodyElement else {
        return nil
    }

    let rendered = renderXHTMLElementChildren(bodyElement).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rendered.isEmpty else {
        return nil
    }

    return """
    <html>
      <head>
        <meta charset=\"utf-8\">
        <style>
          body { font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 13.5px; line-height: 1.45; margin: 0; }
          p { margin: 0 0 0.6em 0; }
          pre { margin: 0.35em 0; padding: 8px 10px; background: rgba(0,0,0,0.06); border-radius: 6px; font-family: SFMono-Regular, Menlo, monospace; font-size: 12.5px; white-space: pre-wrap; }
          code { font-family: SFMono-Regular, Menlo, monospace; }
          table { border-collapse: collapse; margin: 0.4em 0; width: 100%; }
          th, td { border: 1px solid rgba(0,0,0,0.25); text-align: left; padding: 5px 7px; vertical-align: top; }
          thead th { background: rgba(0,0,0,0.08); }
          ul, ol { margin: 0.3em 0 0.5em 1.1em; }
          li { margin: 0.1em 0; }
        </style>
      </head>
      <body>
        \(rendered)
      </body>
    </html>
    """
}

private func parseReplyReference(from element: Element) -> MessageReplyReference? {
    let replyElement = element.children.first {
        ($0.xmlns == replyNamespace && localName(of: $0.name) == "reply") ||
        localName(of: $0.name) == "reply"
    }
    guard let replyElement else {
        return nil
    }

    guard let id = replyElement.attribute("id")?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
        return nil
    }
    let to = replyElement.attribute("to")?.trimmingCharacters(in: .whitespacesAndNewlines)
    return MessageReplyReference(id: id, to: to)
}

private func parseStableMessageId(from element: Element) -> String? {
    var stanzaId: String?
    var originId: String?

    for child in element.children {
        let lname = localName(of: child.name).lowercased()
        guard lname == "stanza-id" || lname == "origin-id" else { continue }

        // XEP-0359 ids are expected in urn:xmpp:sid:0. Be tolerant of
        // parser/namespace variations and still read known element names.
        let ns = child.xmlns ?? ""
        if !ns.isEmpty && ns != sidNamespace {
            continue
        }

        guard let id = child.attribute("id")?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            continue
        }

        if lname == "stanza-id" {
            stanzaId = id
        } else {
            originId = id
        }
    }

    return stanzaId ?? originId
}

private func renderXHTMLElementChildren(_ parent: Element) -> String {
    var out = ""
    if let txt = parent.value, !txt.isEmpty {
        out += escapeHTML(txt)
    }
    for child in parent.children {
        out += renderXHTMLElement(child)
    }
    return out
}

private func renderXHTMLElement(_ element: Element) -> String {
    let rawName = localName(of: element.name).lowercased()
    let allowedTags: Set<String> = [
        "p", "br", "strong", "em", "b", "i", "u", "code", "pre",
        "table", "thead", "tbody", "tr", "th", "td",
        "ul", "ol", "li", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "span", "div"
    ]
    let tag = allowedTags.contains(rawName) ? rawName : "span"

    if tag == "br" {
        return "<br/>"
    }

    let inner = renderXHTMLElementChildren(element)
    return "<\(tag)>\(inner)</\(tag)>"
}

private func escapeHTML(_ s: String) -> String {
    s
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
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

    public enum ThreadEncryptionStatus: Hashable, Sendable {
        case cleartext
        case encrypted
        case requiredUnavailable(String)
        case decryptionFailed(String)
    }

    /// Avatar image bytes keyed by bare JID (XEP-0084 PEP user avatar)
    @Published public private(set) var avatarDataByJid: [String: Data] = [:]
    private var avatarLoadingJids: Set<String> = []

    @Published public private(set) var status: Status = .disconnected
    @Published public private(set) var statusText: String = "Disconnected"
    @Published public private(set) var threadEncryptionStatus: [String: ThreadEncryptionStatus] = [:]
    @Published public private(set) var omemoRequiredThreads: Set<String> = []

    private let messageModule: MessageModule
    private let pubSubModule: PubSubModule
    private let mamModule: MessageArchiveManagementModule
    private let chatStateModule: ChatStateNotificationsModule
    private let httpUploadModule: HttpFileUploadModule
    private let pepUserAvatarModule: PEPUserAvatarModule
    private let vcardTempModule: VCardTempModule
    private var omemoModule: OMEMOModule?
    private var omemoSignalContext: SignalContext?
    private var omemoStorage: SwitchOMEMOStorage?
    private var omemoRegistered = false
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
    private let omemoMarker = "I sent you an OMEMO encrypted message"
    private let omemoRequireMarkedThreads: Bool
    private var decryptedMessageCache: OMEMODecryptedMessageCache?

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

        self.omemoStorage = nil
        self.omemoSignalContext = nil
        self.omemoModule = nil

        let rawMamLast = ProcessInfo.processInfo.environment["SWITCH_MAM_LAST_ITEMS"] ?? "50"
        let parsedMamLast = Int(rawMamLast) ?? 50
        self.mamLastItems = max(10, min(parsedMamLast, 500))

        let rawMamRecencyLast = ProcessInfo.processInfo.environment["SWITCH_MAM_RECENCY_LAST_ITEMS"] ?? "1"
        let parsedMamRecencyLast = Int(rawMamRecencyLast) ?? 1
        self.mamRecencyLastItems = max(1, min(parsedMamRecencyLast, 5))
        self.omemoRequireMarkedThreads = EnvLoader.parseBool(
            ProcessInfo.processInfo.environment["SWITCH_OMEMO_REQUIRE_FOR_MARKED_THREADS"],
            default: true
        )

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
        decryptedMessageCache = OMEMODecryptedMessageCache(account: bareJid(from: config.xmppJid))
        setupOMEMOIfNeeded()
        status = .connecting
        statusText = "Connecting..."
        client.login()
    }

    public func disconnect() {
        _ = client.disconnect()
    }

    public func sendMessage(to bareJid: String, body: String, replyTo: MessageReplyReference? = nil) {
        sendWireMessage(to: bareJid, wireBody: body, displayBody: body, replyTo: replyTo, metaElement: nil, metaForStore: nil)
    }

    public func sendImageAttachment(to bareJid: String, data: Data, filename: String, mime: String, caption: String?, replyTo: MessageReplyReference? = nil) {
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
                    replyTo: replyTo,
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
        sendWireMessage(to: bareJid, wireBody: displayText, displayBody: displayText, replyTo: nil, metaElement: meta, metaForStore: metaForStore)
    }

    public func sendSubagentWork(to subagentJid: String, taskId: String, parentJid: String, body: String) {
        let envelope = SubagentWorkEnvelope(taskId: taskId, parentJid: parentJid, body: body)
        guard let encoded = SubagentWorkCodec.encode(envelope) else {
            return
        }
        sendWireMessage(to: subagentJid, wireBody: encoded, displayBody: body, replyTo: nil, metaElement: nil, metaForStore: nil, allowOMEMO: false)
    }

    private func sendWireMessage(to bareJid: String, wireBody: String, displayBody: String, replyTo: MessageReplyReference?, metaElement: Element?, metaForStore: MessageMeta?, extraElements: [Element] = [], allowOMEMO: Bool = true) {
        let to = BareJID(bareJid)
        let chat = messageModule.chatManager.createChat(for: client, with: to)
        guard let conversation = chat as? ConversationBase else {
            return
        }
        let id = UUID().uuidString
        let msg = conversation.createMessage(text: wireBody, id: id)
        if let replyTo {
            msg.element.addChild(buildReplyElement(replyTo))
        }
        if let metaElement {
            msg.element.addChild(metaElement)
        }
        for el in extraElements {
            msg.element.addChild(el)
        }

        let requireOMEMO = shouldRequireOMEMO(for: bareJid)
        let shouldTryOMEMO = allowOMEMO && (requireOMEMO || (omemoModule?.isAvailable(for: to) ?? false))

        if shouldTryOMEMO, let omemoModule {
            omemoModule.encode(message: msg) { [weak self] result in
                guard let self else { return }
                Task { @MainActor in
                    switch result {
                    case .successMessage(let encrypted, _):
                        conversation.send(message: encrypted, completionHandler: nil)
                        self.threadEncryptionStatus[bareJid] = .encrypted
                        self.chatStore.appendOutgoing(
                            threadJid: bareJid,
                            body: displayBody,
                            replyTo: replyTo,
                            encryption: .encrypted,
                            id: encrypted.id,
                            timestamp: Date(),
                            meta: metaForStore
                        )
                    case .failure(let err):
                        if requireOMEMO && self.omemoRequireMarkedThreads {
                            self.threadEncryptionStatus[bareJid] = .requiredUnavailable("Encryption unavailable: \(self.formatOMEMOError(err))")
                            return
                        }
                        conversation.send(message: msg, completionHandler: nil)
                        self.threadEncryptionStatus[bareJid] = .cleartext
                        self.chatStore.appendOutgoing(threadJid: bareJid, body: displayBody, replyTo: replyTo, encryption: .cleartext, id: msg.id, timestamp: Date(), meta: metaForStore)
                    }
                }
            }
            return
        }

        if requireOMEMO && omemoRequireMarkedThreads {
            threadEncryptionStatus[bareJid] = .requiredUnavailable("Encryption required for this contact")
            return
        }

        conversation.send(message: msg, completionHandler: nil)
        threadEncryptionStatus[bareJid] = .cleartext
        chatStore.appendOutgoing(threadJid: bareJid, body: displayBody, replyTo: replyTo, encryption: .cleartext, id: msg.id, timestamp: Date(), meta: metaForStore)
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

    private func setupOMEMOIfNeeded() {
        if omemoRegistered {
            return
        }

        let storage = SwitchOMEMOStorage(context: client)
        guard let signalContext = SignalContext(withStorage: storage) else {
            logger.error("Unable to initialize SignalContext for OMEMO")
            return
        }
        let module = OMEMOModule(aesGCMEngine: SwitchAESGCMEngine(), signalContext: signalContext, signalStorage: storage)
        module.defaultBody = "I sent you an OMEMO encrypted message but your client doesn’t seem to support that. Find more information on https://conversations.im/omemo"

        self.omemoStorage = storage
        self.omemoSignalContext = signalContext
        self.omemoModule = module
        client.modulesManager.register(module)
        omemoRegistered = true
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
                let hasOMEMOPayload = self.hasOMEMOPayload(received.message.element)
                if hasOMEMOPayload {
                    self.omemoRequiredThreads.insert(from)
                }

                // Track chat state (typing indicators)
                if let chatState = received.message.chatState {
                    switch chatState {
                    case .composing:
                        self.composingJids.insert(from)
                    case .active, .inactive, .paused, .gone:
                        self.composingJids.remove(from)
                    }
                }

                let stableId = parseStableMessageId(from: received.message.element) ?? received.message.id
                let message = received.message
                var body = message.body
                var encryption: MessageEncryptionState = .cleartext

                if hasOMEMOPayload {
                    if let omemoModule {
                        switch omemoModule.decode(message: message, serverMsgId: stableId) {
                        case .successMessage(let decodedMessage, _):
                            body = decodedMessage.body ?? body
                            encryption = .decrypted
                            self.threadEncryptionStatus[from] = .encrypted
                            if let body, !body.isEmpty {
                                self.decryptedMessageCache?.save(body: body, for: stableId)
                            }
                        case .successTransportKey:
                            if let cached = self.decryptedMessageCache?.body(for: stableId) {
                                body = cached
                                encryption = .decrypted
                                self.threadEncryptionStatus[from] = .encrypted
                            } else {
                                encryption = .decryptionFailed
                                self.threadEncryptionStatus[from] = .decryptionFailed("Message payload missing")
                            }
                        case .failure(let err):
                            if let cached = self.decryptedMessageCache?.body(for: stableId) {
                                body = cached
                                encryption = .decrypted
                                self.threadEncryptionStatus[from] = .encrypted
                            } else {
                                encryption = .decryptionFailed
                                self.threadEncryptionStatus[from] = .decryptionFailed("Decryption failed: \(self.formatOMEMOError(err))")
                                if body == nil || body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                                    body = "[Unable to decrypt OMEMO message: \(self.formatOMEMOError(err))]"
                                }
                            }
                        }
                    } else {
                        encryption = .decryptionFailed
                        self.threadEncryptionStatus[from] = .decryptionFailed("OMEMO module unavailable")
                    }
                }

                if body?.contains(self.omemoMarker) == true {
                    self.omemoRequiredThreads.insert(from)
                }

                // Process message body if present
                guard let body else { return }
                // Receiving a message with body means they're done typing
                self.composingJids.remove(from)
                let meta = parseMessageMeta(from: message.element)
                let xhtmlBody = parseXHTMLBody(from: message.element)
                let replyTo = parseReplyReference(from: message.element)
                self.chatStore.appendIncoming(threadJid: from, body: body, xhtmlBody: xhtmlBody, replyTo: replyTo, encryption: encryption, id: stableId, timestamp: message.delay?.stamp ?? Date(), meta: meta)
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

                let message = archived.message
                let hasOMEMOPayload = self.hasOMEMOPayload(message.element)
                if hasOMEMOPayload {
                    self.omemoRequiredThreads.insert(threadJid)
                }

                let localBare = self.client.userBareJid
                let fromBare = archived.message.from?.bareJid
                let direction: ChatMessage.Direction = (fromBare == localBare) ? .outgoing : .incoming
                let id = parseStableMessageId(from: archived.message.element)
                    ?? archived.message.id
                    ?? "mam:\(archived.messageId)"
                var body = message.body
                var encryption: MessageEncryptionState = .cleartext

                if hasOMEMOPayload {
                    if let omemoModule {
                        let decodeFrom = fromBare ?? BareJID(threadJid)
                        switch omemoModule.decode(message: message, from: decodeFrom, serverMsgId: id) {
                        case .successMessage(let decodedMessage, _):
                            body = decodedMessage.body ?? body
                            encryption = .decrypted
                            if let body, !body.isEmpty {
                                self.decryptedMessageCache?.save(body: body, for: id)
                            }
                        case .successTransportKey:
                            if let cached = self.decryptedMessageCache?.body(for: id) {
                                body = cached
                                encryption = .decrypted
                            } else {
                                encryption = .decryptionFailed
                            }
                        case .failure(let err):
                            if let cached = self.decryptedMessageCache?.body(for: id) {
                                body = cached
                                encryption = .decrypted
                            } else {
                                encryption = .decryptionFailed
                                if body == nil || body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                                    body = "[Unable to decrypt OMEMO message: \(self.formatOMEMOError(err))]"
                                }
                            }
                        }
                    } else {
                        encryption = .decryptionFailed
                    }
                }

                guard let body, !body.isEmpty else { return }

                let meta = parseMessageMeta(from: message.element)
                let xhtmlBody = parseXHTMLBody(from: message.element)
                let replyTo = parseReplyReference(from: message.element)

                switch direction {
                case .incoming:
                    self.chatStore.appendIncoming(threadJid: threadJid, body: body, xhtmlBody: xhtmlBody, replyTo: replyTo, encryption: encryption, id: id, timestamp: archived.timestamp, meta: meta, isArchived: true)
                case .outgoing:
                    self.chatStore.appendOutgoing(threadJid: threadJid, body: body, xhtmlBody: xhtmlBody, replyTo: replyTo, encryption: encryption, id: id, timestamp: archived.timestamp, meta: meta, isArchived: true)
                }
            }
            .store(in: &cancellables)
    }

    public func encryptionStatus(for threadJid: String?) -> ThreadEncryptionStatus? {
        guard let threadJid else { return nil }
        if let current = threadEncryptionStatus[threadJid] {
            return current
        }
        if omemoRequiredThreads.contains(threadJid) {
            return .requiredUnavailable("Encryption required")
        }
        return nil
    }

    private func shouldRequireOMEMO(for bareJid: String) -> Bool {
        omemoRequiredThreads.contains(bareJid)
    }

    private func hasOMEMOPayload(_ element: Element) -> Bool {
        element.children.contains { child in
            localName(of: child.name) == "encrypted" && (child.xmlns == omemoNamespace || child.xmlns == OMEMOModule.XMLNS)
        }
    }

    private func formatOMEMOError(_ error: Error) -> String {
        let short = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        let detailed = String(reflecting: error).trimmingCharacters(in: .whitespacesAndNewlines)

        if short.isEmpty && detailed.isEmpty {
            return "unknown"
        }
        if short.isEmpty {
            return detailed
        }
        if detailed.isEmpty || short == detailed {
            return short
        }
        return "\(short) [\(detailed)]"
    }

    private func bareJid(from jid: String) -> String {
        let trimmed = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = trimmed.firstIndex(of: "/") {
            return String(trimmed[..<slash])
        }
        return trimmed
    }
}
