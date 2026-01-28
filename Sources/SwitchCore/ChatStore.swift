import Combine
import Foundation
import Martin

public struct MessageMeta: Hashable, Sendable {
    public enum MetaType: String, Sendable {
        case tool
        case toolResult = "tool-result"
        case unknown
    }

    public let type: MetaType
    public let tool: String?

    public init(type: MetaType, tool: String? = nil) {
        self.type = type
        self.tool = tool
    }

    public var isToolRelated: Bool {
        type == .tool || type == .toolResult
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

    public let liveIncomingMessage = PassthroughSubject<ChatMessage, Never>()

    public init() {}

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
            liveIncomingMessage.send(msg)
        }
    }

    public func appendOutgoing(threadJid: String, body: String, id: String?, timestamp: Date, meta: MessageMeta? = nil) {
        appendIfMissing(
            ChatMessage(
                id: id ?? UUID().uuidString,
                threadJid: threadJid,
                direction: .outgoing,
                body: body,
                timestamp: timestamp,
                meta: meta
            )
        )
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
