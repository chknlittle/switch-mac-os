import Combine
import Foundation

@MainActor
public final class SwitchAppModel: ObservableObject {
    @Published public private(set) var configError: String? = nil
    @Published public private(set) var config: AppConfig? = nil
    @Published public private(set) var xmpp: XMPPService = XMPPService()
    @Published public private(set) var directory: SwitchDirectoryService? = nil

    private var cancellables: Set<AnyCancellable> = []

    public init() {
        do {
            let config = try AppConfig.load()
            self.config = config

            if let dirJid = config.switchDirectoryJid {
                directory = SwitchDirectoryService(
                    xmpp: xmpp,
                    directoryJid: dirJid,
                    pubSubJid: config.inferredPubSubJidIfMissing()
                )
            }

            // Wait for connected state before refreshing directory
            xmpp.$status
                .first { if case .connected = $0 { return true } else { return false } }
                .sink { [weak self] _ in
                    self?.directory?.refreshAll()
                }
                .store(in: &cancellables)

            xmpp.connect(using: config)
        } catch {
            configError = String(describing: error)
        }
    }
}
