import Foundation

public struct AppConfig: Sendable {
    public let xmppHost: String
    public let xmppPort: Int
    public let xmppJid: String
    public let xmppPassword: String
    public let switchDirectoryJid: String?
    public let switchPubSubJid: String?
    public let switchConvenienceDispatchers: [DirectoryItem]

    public init(
        xmppHost: String,
        xmppPort: Int,
        xmppJid: String,
        xmppPassword: String,
        switchDirectoryJid: String?,
        switchPubSubJid: String?,
        switchConvenienceDispatchers: [DirectoryItem]
    ) {
        self.xmppHost = xmppHost
        self.xmppPort = xmppPort
        self.xmppJid = xmppJid
        self.xmppPassword = xmppPassword
        self.switchDirectoryJid = switchDirectoryJid
        self.switchPubSubJid = switchPubSubJid
        self.switchConvenienceDispatchers = switchConvenienceDispatchers
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

        let convenienceDispatchers = parseConvenienceDispatchers(
            env["SWITCH_CONVENIENCE_DISPATCHERS"]
        )

        return AppConfig(
            xmppHost: host,
            xmppPort: port,
            xmppJid: jid,
            xmppPassword: password,
            switchDirectoryJid: directoryJid,
            switchPubSubJid: pubsubJid,
            switchConvenienceDispatchers: convenienceDispatchers
        )
    }

    private static func parseConvenienceDispatchers(_ raw: String?) -> [DirectoryItem] {
        guard let raw else { return [] }

        var result: [DirectoryItem] = []
        var seen: Set<String> = []

        for token in raw.split(separator: ",") {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.isEmpty { continue }

            var label: String? = nil
            var jid = entry
            if let eq = entry.firstIndex(of: "=") {
                label = String(entry[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                jid = String(entry[entry.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if jid.isEmpty || seen.contains(jid) {
                continue
            }
            seen.insert(jid)

            let fallbackName = String(jid.split(separator: "@").first ?? Substring(jid))
            let name = label.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName

            result.append(
                DirectoryItem(
                    jid: jid,
                    name: name,
                    isDirect: true,
                    sortOrder: Int.max
                )
            )
        }

        return result
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
