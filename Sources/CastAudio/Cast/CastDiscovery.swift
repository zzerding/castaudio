import Foundation
import Network

/// The protocol namespaces a Cast device listens on.
enum CastNamespace {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver = "urn:x-cast:com.google.cast.receiver"
    static let media = "urn:x-cast:com.google.cast.media"
    static let deviceAuth = "urn:x-cast:com.google.cast.tp.deviceauth"
}

/// A Cast device found on the local network.
///
/// The endpoint is kept as the Network framework's own type, because a
/// Bonjour result gives a service name rather than an IP address; the
/// framework resolves the name when the connection is opened.
struct CastDevice: Identifiable, Equatable {
    /// Stable identifier: the device id from the Bonjour TXT record.
    var id: String
    /// Friendly name shown in the device list.
    var name: String
    /// The endpoint the Cast V2 channel is opened on.
    var endpoint: NWEndpoint

    /// The Default Media Receiver, which plays an ordinary media URL.
    static let defaultMediaReceiverID = "CC1AD845"

    /// The TCP port the Cast V2 channel listens on.
    static let channelPort: UInt16 = 8009
}

/// Finds Cast devices on the local network using Bonjour.
final class CastDiscovery {
    /// Called whenever the device list changes.
    var onDevicesChanged: (([CastDevice]) -> Void)?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.castaudio.discovery")

    /// Starts looking for `_googlecast._tcp` devices.
    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: "_googlecast._tcp",
            domain: "local."
        )
        let browser = NWBrowser(for: descriptor, using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                NSLog("[CastAudio] Bonjour browsing failed: \(error.localizedDescription)")
                self?.browser = nil
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.publish(results)
        }
        browser.start(queue: queue)
    }

    /// Stops looking for devices.
    func stop() {
        browser?.cancel()
        browser = nil
        onDevicesChanged?([])
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        var found: [String: CastDevice] = [:]
        for result in results {
            guard case let .bonjour(record) = result.metadata else { continue }
            let txt = record.dictionary
            let endpoint = result.endpoint

            let id: String
            let name: String
            switch endpoint {
            case let .service(serviceName, _, _, _):
                id = txt["id"] ?? serviceName
                name = txt["fn"] ?? serviceName
            case let .hostPort(host, _):
                let hostName = host.debugDescription
                id = txt["id"] ?? hostName
                name = txt["fn"] ?? hostName
            default:
                continue
            }
            found[id] = CastDevice(id: id, name: name, endpoint: endpoint)
        }
        onDevicesChanged?(Array(found.values).sorted { $0.name < $1.name })
    }
}
