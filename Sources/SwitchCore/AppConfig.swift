import Foundation

public struct PinnedChat: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let jid: String

    public init(title: String, jid: String) {
        self.title = title
        self.jid = jid
        self.id = jid
    }
}

public struct AppConfig: Sendable {
    public let xmppHost: String
    public let xmppPort: Int
    public let xmppJid: String
    public let xmppPassword: String
    public let switchDirectoryJid: String?
    public let switchPubSubJid: String?
    public let pinnedChats: [PinnedChat]

    public init(
        xmppHost: String,
        xmppPort: Int,
        xmppJid: String,
        xmppPassword: String,
        switchDirectoryJid: String?,
        switchPubSubJid: String?,
        pinnedChats: [PinnedChat]
    ) {
        self.xmppHost = xmppHost
        self.xmppPort = xmppPort
        self.xmppJid = xmppJid
        self.xmppPassword = xmppPassword
        self.switchDirectoryJid = switchDirectoryJid
        self.switchPubSubJid = switchPubSubJid
        self.pinnedChats = pinnedChats
    }

    public static func load() throws -> AppConfig {
        let env = EnvLoader.loadMergedEnv()

        let rawHost = try EnvLoader.require(env, key: "XMPP_HOST")
        let (host, port) = EnvLoader.parseHostPort(rawHost, defaultPort: 5222)

        let jid = try EnvLoader.require(env, key: "XMPP_JID")
        let password = try EnvLoader.require(env, key: "XMPP_PASSWORD")

        let directory = env["SWITCH_DIRECTORY_JID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var directoryJid = (directory?.isEmpty == false) ? directory : nil
        // Mirror server behavior: if the caller provides a bare JID, add a stable
        // resource so disco#items reaches the connected client (not ejabberd PEP).
        if let d = directoryJid, !d.contains("/") {
            directoryJid = d + "/directory"
        }

        let pubsub = env["SWITCH_PUBSUB_JID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pubsubJid = (pubsub?.isEmpty == false) ? pubsub : nil

        let pinnedChats = EnvLoader.loadPinnedChats(env)

        return AppConfig(
            xmppHost: host,
            xmppPort: port,
            xmppJid: jid,
            xmppPassword: password,
            switchDirectoryJid: directoryJid,
            switchPubSubJid: pubsubJid,
            pinnedChats: pinnedChats
        )
    }
}

extension AppConfig {
    public func inferredPubSubJidIfMissing() -> String? {
        if let explicit = switchPubSubJid {
            return explicit
        }
        // Best-effort: if the account domain is a DNS name, ejabberd pubsub is usually pubsub.<domain>.
        let parts = xmppJid.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let domain = String(parts[1])
        return "pubsub.\(domain)"
    }
}

public enum EnvLoader {
    public enum Error: Swift.Error, CustomStringConvertible {
        case missingKey(String)
        case unreadableDotEnv(String)

        public var description: String {
            switch self {
            case .missingKey(let key):
                return "Missing required env var: \(key)"
            case .unreadableDotEnv(let message):
                return "Unable to read .env: \(message)"
            }
        }
    }

    public static func loadMergedEnv() -> [String: String] {
        var merged = ProcessInfo.processInfo.environment

        // Lowest precedence: bundle Resources/.env (used by ./bundle.sh for local dev)
        if let resources = Bundle.main.resourceURL?.path,
           let dotEnv = try? readDotEnv(at: resources + "/.env") {
            for (k, v) in dotEnv { merged[k] = v }
        }

        // Next: current working directory .env (CLI + repo-root dev)
        if let dotEnv = try? readDotEnv(at: FileManager.default.currentDirectoryPath + "/.env") {
            for (k, v) in dotEnv { merged[k] = v }
        }

        // Highest precedence: explicit path override
        if let path = ProcessInfo.processInfo.environment["SWITCH_DOTENV_PATH"],
           let dotEnv = try? readDotEnv(at: path) {
            for (k, v) in dotEnv { merged[k] = v }
        }

        return merged
    }

    public static func require(_ env: [String: String], key: String) throws -> String {
        guard let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw Error.missingKey(key)
        }
        return value
    }

    public static func parseHostPort(_ raw: String, defaultPort: Int) -> (String, Int) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<colon])
            let portStr = String(trimmed[trimmed.index(after: colon)...])
            if let port = Int(portStr), !host.isEmpty {
                return (host, port)
            }
        }
        return (trimmed, defaultPort)
    }

    public static func loadPinnedChats(_ env: [String: String]) -> [PinnedChat] {
        // Open source default: no pinned chats.
        //
        // Preferred format:
        //   SWITCH_PINNED_CHATS="label=jid,other=jid2"
        // You may also provide bare JIDs:
        //   SWITCH_PINNED_CHATS="jid1,jid2"
        let raw = env["SWITCH_PINNED_CHATS"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty {
            return parsePinnedChats(raw)
        }
        return []
    }

    private static func parsePinnedChats(_ raw: String) -> [PinnedChat] {
        let parts = raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" || $0 == ";" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen: Set<String> = []
        var out: [PinnedChat] = []
        out.reserveCapacity(parts.count)

        for p in parts {
            let title: String
            let jid: String

            if let eq = p.firstIndex(of: "=") {
                title = String(p[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                jid = String(p[p.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                title = ""
                jid = p
            }

            let trimmedJid = jid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedJid.isEmpty else { continue }
            guard !seen.contains(trimmedJid) else { continue }
            seen.insert(trimmedJid)

            let finalTitle = title.isEmpty ? inferPinnedTitle(fromJid: trimmedJid) : title
            out.append(PinnedChat(title: finalTitle, jid: trimmedJid))
        }
        return out
    }

    private static func inferPinnedTitle(fromJid jid: String) -> String {
        let s = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = s.firstIndex(of: "@") {
            let local = String(s[..<at])
            if !local.isEmpty {
                return local
            }
        }
        return s
    }

    private static func readDotEnv(at path: String) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: path) else {
            return [:]
        }
        do {
            let data = try String(contentsOfFile: path, encoding: .utf8)
            return parseDotEnv(data)
        } catch {
            throw Error.unreadableDotEnv(String(describing: error))
        }
    }

    private static func parseDotEnv(_ contents: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty {
                out[key] = value
            }
        }
        return out
    }
}
