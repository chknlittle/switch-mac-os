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
                    pubSubJid: config.inferredPubSubJidIfMissing(),
                    convenienceDispatchers: config.switchConvenienceDispatchers
                )
            }

            // Refresh the directory on initial connect and after reconnects.
            xmpp.$status
                .sink { [weak self] status in
                    guard case .connected = status else { return }
                    self?.directory?.refreshAll()
                }
                .store(in: &cancellables)

            xmpp.connect(using: config)
        } catch {
            configError = String(describing: error)
        }
    }
}
