import Foundation
import Network
import Security

/// The caller of one request, as TLS proved it.
struct PeerClient {
    /// Fingerprint of the client certificate. Every phone has one, also before it pairs.
    var fingerprint: String
    /// The address the request came from. A phone's own server listens there too.
    var host: String?
}

/// HTTPS listener for the peer API, advertised with Bonjour as `_glimpse._tcp`.
/// TLS requires a client certificate; the request handler decides what an unpaired certificate may do.
final class PeerServer {
    static let serviceType = "_glimpse._tcp"
    /// A fixed port makes a reconnect without Bonjour possible. Another free port is used when it is taken.
    static let preferredPort: UInt16 = 53_817

    enum State: Equatable {
        case starting, ready(port: UInt16), failed(String)
    }

    typealias Handler = @Sendable (HTTPRequest, PeerClient) async -> HTTPResponse

    private let identity: PeerIdentity
    private let queue = DispatchQueue(label: "Glimpse.PeerServer")
    private let handler: Handler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: PeerConnection] = [:]
    private var onState: (State) -> Void = { _ in }

    init(identity: PeerIdentity, handler: @escaping Handler) {
        self.identity = identity
        self.handler = handler
    }

    func start(name: String, txt: [String: String], onState: @escaping (State) -> Void) {
        self.onState = onState
        queue.async { self.listen(name: name, txt: txt, port: Self.preferredPort) }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func listen(name: String, txt: [String: String], port: UInt16?) {
        let parameters = NWParameters(tls: tlsOptions(), tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            if let port, let endpoint = NWEndpoint.Port(rawValue: port) {
                listener = try NWListener(using: parameters, on: endpoint)
            } else {
                listener = try NWListener(using: parameters)
            }
        } catch {
            if port != nil { return listen(name: name, txt: txt, port: nil) }
            onState(.failed(error.localizedDescription))
            return
        }
        listener.service = NWListener.Service(name: name, type: Self.serviceType, domain: nil,
                                              txtRecord: NWTXTRecord(txt))
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                self.onState(.ready(port: listener.port?.rawValue ?? 0))
            case .failed(let error):
                listener.cancel()
                // The preferred port is taken: try any port.
                if port != nil, case .posix(.EADDRINUSE) = error {
                    self.listen(name: name, txt: txt, port: nil)
                } else {
                    self.onState(.failed(error.localizedDescription))
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        onState(.starting)
        listener.start(queue: queue)
    }

    private func tlsOptions() -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let identity = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(options, identity)
        }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(options, true)
        // Client certificates are self-signed. Trust is decided per request by fingerprint, not by a CA.
        sec_protocol_options_set_verify_block(options, { _, _, complete in complete(true) }, queue)
        return tls
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = PeerConnection(connection: nwConnection, queue: queue, handler: handler)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.onClose = { [weak self] in
            self?.connections[key] = nil
        }
        connection.start()
    }
}

/// One TLS connection: reads requests one by one and answers each before it reads the next.
/// All state is used on the server queue only.
private final class PeerConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: PeerServer.Handler
    private var buffer = Data()
    private var client: PeerClient?
    var onClose: () -> Void = {}

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping PeerServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let fingerprint = self.peerFingerprint() else { return self.cancel() }
                self.client = PeerClient(fingerprint: fingerprint, host: self.remoteHost())
                self.receive()
            case .failed, .cancelled:
                self.onClose()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    private func remoteHost() -> String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: return nil
        }
        // An IPv4 client of a dual-stack listener shows as "::ffff:10.0.0.2".
        return text.hasPrefix("::ffff:") && text.contains(".") ? String(text.dropFirst(7)) : text
    }

    private func peerFingerprint() -> String? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        var leaf: Data?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            guard leaf == nil else { return }
            let reference = sec_certificate_copy_ref(certificate).takeRetainedValue()
            leaf = SecCertificateCopyData(reference) as Data
        }
        return leaf.map(PeerIdentity.fingerprint(ofCertificate:))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            do {
                if let request = try HTTPRequest.parse(&self.buffer) {
                    self.respond(to: request)
                } else if isComplete || error != nil {
                    self.cancel()
                } else {
                    self.receive()
                }
            } catch {
                let status = (error as? HTTPRequest.ParseError) == .tooLarge ? 413 : 400
                self.send(.error(status, "bad_request", "The request could not be read."), keepAlive: false)
            }
        }
    }

    private func respond(to request: HTTPRequest) {
        guard let client else { return cancel() }
        let handler = handler
        Task {
            let response = await handler(request, client)
            self.queue.async { self.send(response, keepAlive: request.keepAlive) }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        connection.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if keepAlive, error == nil {
                // A pipelined request may already wait in the buffer.
                if let next = try? HTTPRequest.parse(&self.buffer) {
                    self.respond(to: next)
                } else {
                    self.receive()
                }
            } else {
                self.cancel()
            }
        })
    }
}
