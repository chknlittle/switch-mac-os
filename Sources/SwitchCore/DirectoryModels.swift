import Foundation

public struct DirectoryItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let jid: String
    public let name: String
    /// True for dispatchers that have no sessions (e.g. external bridges).
    public let isDirect: Bool
    /// Server-defined display order (parsed from disco node attribute).
    public let sortOrder: Int

    public init(jid: String, name: String?, isDirect: Bool = false, sortOrder: Int = Int.max) {
        self.jid = jid
        self.name = name ?? jid
        self.id = jid
        self.isDirect = isDirect
        self.sortOrder = sortOrder
    }
}

public enum NavigationSelection: Hashable, Sendable {
    case dispatcher(String)
    case group(String)
    case individual(String)
    case subagent(String)
}

public enum ChatTarget: Hashable, Sendable {
    case dispatcher(String)
    case individual(String)
    case subagent(String)
}

public extension ChatTarget {
    var jid: String {
        switch self {
        case .dispatcher(let jid), .individual(let jid), .subagent(let jid):
            return jid
        }
    }
}

public struct SwitchDirectoryNodes: Sendable {
    public var dispatchers: String = "dispatchers"
    /// Direct dispatcher→sessions node (skips groups indirection).
    public var sessions: @Sendable (String) -> String = { dispatcherJid in "sessions:\(dispatcherJid)" }
    // Legacy nodes (kept for reference but no longer queried by default).
    public var groups: @Sendable (String) -> String = { dispatcherJid in "groups:\(dispatcherJid)" }
    public var individuals: @Sendable (String) -> String = { groupJid in "individuals:\(groupJid)" }
    public var subagents: @Sendable (String) -> String = { individualJid in "subagents:\(individualJid)" }

    public init() {}
}
