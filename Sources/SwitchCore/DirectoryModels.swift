import Foundation

public struct DirectoryItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let jid: String
    public let name: String

    public init(jid: String, name: String?) {
        self.jid = jid
        self.name = name ?? jid
        self.id = jid
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
    public var groups: (String) -> String = { dispatcherJid in "groups:\(dispatcherJid)" }
    public var individuals: (String) -> String = { groupJid in "individuals:\(groupJid)" }
    public var subagents: (String) -> String = { individualJid in "subagents:\(individualJid)" }

    public init() {}
}
