import Combine
import Foundation
import Martin

public struct MessageMeta: Hashable, Sendable {
    public enum MetaType: String, Sendable {
        case tool
        case toolResult = "tool-result"
        case runStats = "run-stats"
        case question
        case questionReply = "question-reply"
        case attachment
        case unknown
    }

    public let type: MetaType
    public let tool: String?
    public let runStats: RunStats?
    public let requestId: String?
    public let question: SwitchQuestionEnvelopeV1?
    public let attachments: [SwitchAttachment]?

    public init(
        type: MetaType,
        tool: String? = nil,
        runStats: RunStats? = nil,
        requestId: String? = nil,
        question: SwitchQuestionEnvelopeV1? = nil,
        attachments: [SwitchAttachment]? = nil
    ) {
        self.type = type
        self.tool = tool
        self.runStats = runStats
        self.requestId = requestId
        self.question = question
        self.attachments = attachments
    }

    public var isToolRelated: Bool {
        type == .tool || type == .toolResult
    }

    public var isQuestionRelated: Bool {
        type == .question || type == .questionReply
    }

    public var isAttachmentRelated: Bool {
        type == .attachment
    }
}

public struct RunStats: Hashable, Sendable {
    public let engine: String?
    public let model: String?
    public let tokensIn: String?
    public let tokensOut: String?
    public let tokensReasoning: String?
    public let tokensCacheRead: String?
    public let tokensCacheWrite: String?
    public let tokensTotal: String?
    public let contextWindow: String?
    public let turns: String?
    public let toolCount: String?
    public let costUsd: String?
    public let durationS: String?
    public let summary: String?

    public init(
        engine: String? = nil,
        model: String? = nil,
        tokensIn: String? = nil,
        tokensOut: String? = nil,
        tokensReasoning: String? = nil,
        tokensCacheRead: String? = nil,
        tokensCacheWrite: String? = nil,
        tokensTotal: String? = nil,
        contextWindow: String? = nil,
        turns: String? = nil,
        toolCount: String? = nil,
        costUsd: String? = nil,
        durationS: String? = nil,
        summary: String? = nil
    ) {
        self.engine = engine
        self.model = model
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.tokensReasoning = tokensReasoning
        self.tokensCacheRead = tokensCacheRead
        self.tokensCacheWrite = tokensCacheWrite
        self.tokensTotal = tokensTotal
        self.contextWindow = contextWindow
        self.turns = turns
        self.toolCount = toolCount
        self.costUsd = costUsd
        self.durationS = durationS
        self.summary = summary
    }
}

public struct ChatMessage: Identifiable, Hashable, Sendable {
    public enum Direction: String, Sendable {
        case incoming
        case outgoing
    }

    public let id: String
    public let threadJid: String
    public let direction: Direction
    public let body: String
    public let timestamp: Date
    public let meta: MessageMeta?

    public init(id: String, threadJid: String, direction: Direction, body: String, timestamp: Date, meta: MessageMeta? = nil) {
        self.id = id
        self.threadJid = threadJid
        self.direction = direction
        self.body = body
        self.timestamp = timestamp
        self.meta = meta
    }
}

@MainActor
public final class ChatStore: ObservableObject {
    @Published public private(set) var threads: [String: [ChatMessage]] = [:]

    @Published public private(set) var unreadByThread: [String: Int] = [:]
    @Published public private(set) var activeThreadJid: String? = nil

    public let liveIncomingMessage = PassthroughSubject<ChatMessage, Never>()
    public let liveOutgoingMessage = PassthroughSubject<ChatMessage, Never>()

    public init() {}

    public func setActiveThread(_ threadJid: String?) {
        activeThreadJid = threadJid
        if let t = threadJid {
            markRead(threadJid: t)
        }
    }

    public func markRead(threadJid: String) {
        if unreadByThread[threadJid] != nil {
            unreadByThread[threadJid] = nil
        }
    }

    public func unreadCount(for threadJid: String) -> Int {
        unreadByThread[threadJid] ?? 0
    }

    public func messages(for threadJid: String) -> [ChatMessage] {
        threads[threadJid] ?? []
    }

    public func appendIncoming(threadJid: String, body: String, id: String?, timestamp: Date, meta: MessageMeta? = nil, isArchived: Bool = false) {
        let msg = ChatMessage(
            id: id ?? UUID().uuidString,
            threadJid: threadJid,
            direction: .incoming,
            body: body,
            timestamp: timestamp,
            meta: meta
        )
        let inserted = appendIfMissing(msg)
        if inserted && !isArchived {
            if activeThreadJid != threadJid {
                unreadByThread[threadJid, default: 0] += 1
            }
            liveIncomingMessage.send(msg)
        }
    }

    public func appendOutgoing(threadJid: String, body: String, id: String?, timestamp: Date, meta: MessageMeta? = nil, isArchived: Bool = false) {
        let msg = ChatMessage(
            id: id ?? UUID().uuidString,
            threadJid: threadJid,
            direction: .outgoing,
            body: body,
            timestamp: timestamp,
            meta: meta
        )
        let inserted = appendIfMissing(msg)
        if inserted && !isArchived {
            // If we send a message in a thread, treat it as read.
            markRead(threadJid: threadJid)
            liveOutgoingMessage.send(msg)
        }
    }

    @discardableResult
    private func appendIfMissing(_ message: ChatMessage) -> Bool {
        var arr = threads[message.threadJid] ?? []
        if arr.contains(where: { $0.id == message.id }) {
            return false
        }
        arr.append(message)
        arr.sort { $0.timestamp < $1.timestamp }
        threads[message.threadJid] = arr
        return true
    }
}
