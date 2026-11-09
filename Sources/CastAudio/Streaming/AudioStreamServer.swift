import Foundation
import Network

/// Serves the encoded audio over HTTP on the local network so a Cast device
/// can pull it.
///
/// The Cast Default Media Receiver fetches the media URL itself, so the
/// stream has to be reachable from the speaker: the URL must carry the Mac's
/// LAN address, not `localhost`.
final class AudioStreamServer {
    enum ServerError: Error {
        case cannotBind
        case notListening
    }

    /// Port the server listens on. Zero means "pick a free one".
    private(set) var port: UInt16 = 0

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.castaudio.streamserver")
    /// Frames queued for clients that have not connected yet. Cast devices
    /// often connect a moment after the load request, so the head of the
    /// stream is kept to let them join mid-stream.
    private var backlog = Data()
    private let backlogLimit = 256 * 1024

    /// Called when a client connects or disconnects, for UI feedback.
    var onClientCountChange: ((Int) -> Void)?

    /// Starts the server.
    func start(port requestedPort: UInt16 = 0) throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: .any) else {
            throw ServerError.cannotBind
        }
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        var bindError: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                bindError = error
                ready.signal()
            case .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)

        if let bindError {
            listener.cancel()
            self.listener = nil
            throw bindError
        }
        if port == 0 {
            listener.cancel()
            self.listener = nil
            throw ServerError.notListening
        }
    }

    /// Stops the server and closes all connections.
    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        backlog.removeAll()
        port = 0
    }

    /// The URL a Cast device should pull the stream from.
    ///
    /// The LAN address is used on purpose: `localhost` on this Mac does not
    /// mean anything to the speaker.
    func streamURL(path: String = "/audio.aac") -> URL? {
        guard port != 0, let host = LocalNetworkAddress.lanAddress() else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = path
        return components.url
    }

    /// Broadcasts a chunk of audio to every connected client.
    func broadcast(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections.values {
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
            if self.connections.isEmpty {
                self.backlog.append(data)
                if self.backlog.count > self.backlogLimit {
                    self.backlog.removeFirst(self.backlog.count - self.backlogLimit)
                }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHeaders(on: connection)
                if !self.backlog.isEmpty {
                    connection.send(content: self.backlog, completion: .contentProcessed { _ in })
                }
                self.onClientCountChange?(self.connections.count)
            case .failed, .cancelled:
                self.connections.removeValue(forKey: id)
                self.onClientCountChange?(self.connections.count)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Minimal HTTP response head for a chunked stream.
    private func sendHeaders(on connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: audio/aac\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
    }
}

/// Finds the machine's address on the local network.
enum LocalNetworkAddress {
    /// The first non-loopback IPv4 address, preferring the usual LAN
    /// interfaces.
    static func lanAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                let isLoopback = name == "lo0"
                if !isLoopback {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &host,
                        socklen_t(host.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let value = String(cString: host)
                        if !value.isEmpty, address == nil || name == "en0" {
                            address = value
                        }
                    }
                }
            }
            pointer = interface.ifa_next
        }
        return address
    }
}
